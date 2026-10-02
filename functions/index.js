// Import everything from the top-level firebase-functions package.
// Using the submodule path (firebase-functions/v2/firestore) hangs the
// Firebase CLI's analysis process on Node.js 24; the main package works fine.
const {
  firestore: { onDocumentCreated, onDocumentDeleted },
  scheduler: { onSchedule },
  logger,
} = require('firebase-functions');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');

initializeApp();

// ── Helpers ────────────────────────────────────────────────────────────────────

const REMINDER_MESSAGES = [
  "Don't forget to note your expenses today! 💰",
  "Leave ahead, make a plan — check your calendar. 🗓️",
  "Small savings today, big dreams tomorrow. 📈",
  "Have you planned your week yet? Open Calendar! 📋",
  "A little note now saves a lot of confusion later. 📝",
  "Track your spending, control your future. 💡",
  "Your calendar is waiting — what's on for today? ☀️",
  "Don't let expenses pile up — log them now! 🧾",
  "Plan smart, live better. Open Calendar. 🌟",
  "A quick note a day keeps the budget on track. 🎯",
  "Check your Tamil Nadu holidays — plan your next break! 🎉",
  "Have you reviewed last month's expenses? 📊",
  "Stay organised, stay stress-free. 🧘",
  "New day, new plan — open your calendar! 🌅",
  "Every rupee counts — track it with Calendar. ₹",
];

function randomMessage() {
  return REMINDER_MESSAGES[Math.floor(Math.random() * REMINDER_MESSAGES.length)];
}

/**
 * Extracts the Cloud Storage object path from a Firebase download URL.
 * Format: https://firebasestorage.googleapis.com/v0/b/BUCKET/o/ENCODED%2FPATH?alt=media&token=…
 */
function storagePathFromUrl(url) {
  if (!url) return null;
  try {
    const u = new URL(url);
    const oIndex = u.pathname.indexOf('/o/');
    if (oIndex === -1) return null;
    return decodeURIComponent(u.pathname.slice(oIndex + 3));
  } catch {
    return null;
  }
}

/**
 * Deletes a media file from Cloud Storage by its download URL.
 * Silently ignores 404 (already gone) and null/empty URLs.
 */
async function deleteMediaFile(url) {
  const path = storagePathFromUrl(url);
  if (!path) return;
  try {
    const { getStorage } = require('firebase-admin/storage');
    await getStorage().bucket().file(path).delete();
    logger.info('Deleted media file', { path });
  } catch (err) {
    if (err.code !== 404) {
      logger.warn('Media delete failed (non-404)', { path, code: err.code });
    }
  }
}

// ── Device tokens ──────────────────────────────────────────────────────────────

/**
 * Every FCM token registered for a user, across all their devices.
 *
 * Tokens live in user_profiles/{uid}/devices, one document per device, because
 * a token identifies an app install — not a person. The profile's legacy
 * `fcmToken` field held exactly one, so signing in on a second device
 * overwrote the first and only the newest device was ever reachable. That
 * field is still read here so a device that has not yet run the new client
 * keeps receiving notifications.
 *
 * Returns a Map of token → the document to delete if FCM rejects it (null for
 * the legacy field, which is cleared differently).
 */
async function tokensForUser(db, uid) {
  const tokens = new Map();
  const profileRef = db.collection('user_profiles').doc(uid);

  const [devices, profile] = await Promise.all([
    profileRef.collection('devices').get().catch(() => null),
    profileRef.get().catch(() => null),
  ]);

  if (devices) {
    devices.forEach((doc) => {
      const token = doc.data().token;
      if (token) tokens.set(token, doc.ref);
    });
  }
  // Legacy single-token field. Map keying dedupes it against the subcollection.
  if (profile && profile.exists) {
    const legacy = profile.data().fcmToken;
    if (legacy && !tokens.has(legacy)) tokens.set(legacy, null);
  }
  return tokens;
}

/** FCM rejects a batch larger than this. */
const MULTICAST_LIMIT = 500;

function chunk(arr, size) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

/**
 * Sends one notification to every device of every uid in [uids].
 *
 * Tokens are deduplicated across recipients, so a device never receives the
 * same message twice. Tokens FCM reports as dead are removed, which keeps the
 * device list from growing stale as apps are uninstalled and reinstalled.
 */
async function notifyUsers(db, uids, { body, data, channelId }) {
  const unique = Array.from(new Set(uids)).filter(Boolean);
  if (unique.length === 0) return;

  const maps = await Promise.all(unique.map((uid) => tokensForUser(db, uid)));

  /** @type {Map<string, {uid: string, ref: FirebaseFirestore.DocumentReference|null}>} */
  const byToken = new Map();
  unique.forEach((uid, i) => {
    for (const [token, ref] of maps[i]) {
      if (!byToken.has(token)) byToken.set(token, { uid, ref });
    }
  });
  if (byToken.size === 0) return;

  const allTokens = Array.from(byToken.keys());
  const dead = [];

  for (const batch of chunk(allTokens, MULTICAST_LIMIT)) {
    let response;
    try {
      response = await getMessaging().sendEachForMulticast({
        tokens: batch,
        notification: { title: 'Calendar', body },
        android: {
          notification: { channelId, priority: 'high', sound: 'default' },
        },
        data,
      });
    } catch (err) {
      logger.error('FCM multicast failed', err);
      continue;
    }

    response.responses.forEach((result, i) => {
      if (result.success) return;
      const code = result.error && result.error.code;
      if (
        code === 'messaging/registration-token-not-registered' ||
        code === 'messaging/invalid-registration-token' ||
        code === 'messaging/invalid-argument'
      ) {
        dead.push(batch[i]);
      } else {
        logger.warn('FCM send failed', { code });
      }
    });
  }

  await Promise.all(
    dead.map(async (token) => {
      const entry = byToken.get(token);
      if (!entry) return;
      try {
        if (entry.ref) {
          await entry.ref.delete();
        } else {
          await db
            .collection('user_profiles')
            .doc(entry.uid)
            .update({ fcmToken: null });
        }
      } catch (err) {
        logger.warn('Token cleanup failed', { code: err.code });
      }
    })
  );
}

const CHAT_CHANNEL = 'tn_calendar_chat';
const CALL_CHANNEL = 'tn_calendar_call_v4';

// ── Incoming call notification ─────────────────────────────────────────────────

exports.onCallCreated = onDocumentCreated(
  'calls/{callId}',
  async (event) => {
    const callData = event.data.data();
    if (callData.status !== 'calling') return;

    const calleeId  = callData.calleeId;
    const callerId  = callData.callerId;
    const callId    = event.params.callId;
    const db        = getFirestore();

    const [calleeDoc, callerDoc] = await Promise.all([
      db.collection('user_profiles').doc(calleeId).get(),
      db.collection('user_profiles').doc(callerId).get(),
    ]);
    if (!calleeDoc.exists) return;

    const callerName = callerDoc.exists ? callerDoc.data().name : 'Unknown';

    // Every signed-in device rings, so the call is not missed just because the
    // callee happens to be holding a different phone.
    await notifyUsers(db, [calleeId], {
      body: 'Calling from your calendar, track expenses wisely!',
      channelId: CALL_CHANNEL,
      data: {
        type:       'incoming_call',
        callId:     callId,
        callerId:   callerId,
        callerName: callerName,
        callType:   callData.type,
      },
    });
  }
);

// ── Chat message notification ──────────────────────────────────────────────────

exports.sendChatNotification = onDocumentCreated(
  'chats/{chatId}/messages/{messageId}',
  async (event) => {
    const message  = event.data.data();
    const chatId   = event.params.chatId;
    const senderId = message.senderId;

    if (!senderId) return;

    const chatDoc = await getFirestore().collection('chats').doc(chatId).get();
    if (!chatDoc.exists) return;

    const participants = chatDoc.data().participants;
    if (!participants || participants.length < 2) return;

    const recipientId = participants.find((uid) => uid !== senderId);
    if (!recipientId) return;

    await notifyUsers(getFirestore(), [recipientId], {
      body: randomMessage(),
      channelId: CHAT_CHANNEL,
      data: {
        chatId:   chatId,
        senderId: senderId,
      },
    });
  }
);

// ── Group chat message notification ───────────────────────────────────────────

/**
 * Group messages had no server-side notification at all — only an in-app
 * listener, which cannot fire once the app is backgrounded or killed. This is
 * the group counterpart to sendChatNotification.
 *
 * Muting is honoured through the group document's `mutedBy` array, since a
 * Cloud Function cannot see a device's local preferences. A message that
 * @mentions someone still reaches them, matching the in-app behaviour.
 */
exports.sendGroupNotification = onDocumentCreated(
  'group_chats/{groupId}/messages/{messageId}',
  async (event) => {
    const message = event.data?.data();
    if (!message) return;

    const senderId = message.senderId;
    if (!senderId) return;

    const groupId = event.params.groupId;
    const db      = getFirestore();

    const groupDoc = await db.collection('group_chats').doc(groupId).get();
    if (!groupDoc.exists) return;

    const group        = groupDoc.data();
    const participants = group.participants || [];
    const mutedBy      = group.mutedBy || [];
    const mentions     = message.mentions || [];

    const recipients = participants.filter(
      (uid) =>
        uid !== senderId && (!mutedBy.includes(uid) || mentions.includes(uid))
    );
    if (recipients.length === 0) return;

    await notifyUsers(db, recipients, {
      body: randomMessage(),
      channelId: CHAT_CHANNEL,
      data: {
        type:     'group_message',
        groupId:  groupId,
        senderId: senderId,
      },
    });
  }
);

// ── Media cleanup on message deletion ─────────────────────────────────────────

/**
 * Fires whenever a personal-chat message is deleted — by Firestore TTL
 * (expireAt field) or by a user manually removing it.
 * Deletes any associated audio/image/video from Cloud Storage.
 */
exports.onPersonalMessageDeleted = onDocumentDeleted(
  'chats/{chatId}/messages/{messageId}',
  async (event) => {
    const data = event.data?.data();
    if (!data) return;
    await Promise.all([
      deleteMediaFile(data.audioUrl),
      deleteMediaFile(data.imageUrl),
      deleteMediaFile(data.videoUrl),
      deleteMediaFile(data.videoThumbUrl),
    ]);
  }
);

/**
 * Same as onPersonalMessageDeleted but for group-chat messages.
 */
exports.onGroupMessageDeleted = onDocumentDeleted(
  'group_chats/{groupId}/messages/{messageId}',
  async (event) => {
    const data = event.data?.data();
    if (!data) return;
    await Promise.all([
      deleteMediaFile(data.audioUrl),
      deleteMediaFile(data.imageUrl),
      deleteMediaFile(data.videoUrl),
      deleteMediaFile(data.videoThumbUrl),
    ]);
  }
);

// ── Expired status cleanup ────────────────────────────────────────────────────

/**
 * Statuses stop being visible after 24h because the client queries on
 * `expiresAt`, but nothing used to remove them — so both the document and its
 * photo/video lingered in Storage forever. This reclaims them once an hour.
 *
 * Deletes are batched (Firestore caps a batch at 500 writes) and the media is
 * removed first, so a failure part-way leaves a document we will retry rather
 * than an orphaned file we can no longer find the URL for.
 */
exports.cleanupExpiredStatuses = onSchedule('every 1 hours', async () => {
  const db = getFirestore();
  const BATCH_LIMIT = 400;
  let totalDeleted = 0;

  // Loop so a large backlog (every status ever posted, on first run) drains
  // across several passes instead of overrunning the batch limit.
  for (;;) {
    const expired = await db
      .collection('statuses')
      .where('expiresAt', '<', new Date())
      .limit(BATCH_LIMIT)
      .get();

    if (expired.empty) break;

    await Promise.all(
      expired.docs.map((doc) => deleteMediaFile(doc.data().mediaUrl))
    );

    const batch = db.batch();
    for (const doc of expired.docs) batch.delete(doc.ref);
    await batch.commit();

    totalDeleted += expired.size;
    if (expired.size < BATCH_LIMIT) break;
  }

  if (totalDeleted > 0) {
    logger.info('Cleaned up expired statuses', { count: totalDeleted });
  }
});
