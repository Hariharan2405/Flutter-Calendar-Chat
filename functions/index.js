// Import everything from the top-level firebase-functions package.
// Using the submodule path (firebase-functions/v2/firestore) hangs the
// Firebase CLI's analysis process on Node.js 24; the main package works fine.
const { firestore: { onDocumentCreated, onDocumentDeleted }, logger } = require('firebase-functions');
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

    const fcmToken   = calleeDoc.data().fcmToken;
    if (!fcmToken) return;

    const callerName = callerDoc.exists ? callerDoc.data().name : 'Unknown';

    try {
      await getMessaging().send({
        token: fcmToken,
        notification: {
          title: 'Calendar',
          body: 'Calling from your calendar, track expenses wisely!',
        },
        android: {
          notification: {
            channelId: 'tn_calendar_call_v4',
            priority: 'high',
            sound: 'default',
          },
        },
        data: {
          type:       'incoming_call',
          callId:     callId,
          callerId:   callerId,
          callerName: callerName,
          callType:   callData.type,
        },
      });
    } catch (err) {
      logger.error('FCM call send failed', err);
      if (
        err.code === 'messaging/invalid-registration-token' ||
        err.code === 'messaging/registration-token-not-registered'
      ) {
        await db.collection('user_profiles').doc(calleeId).update({ fcmToken: null });
      }
    }
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

    const recipientDoc = await getFirestore()
      .collection('user_profiles')
      .doc(recipientId)
      .get();
    if (!recipientDoc.exists) return;

    const fcmToken = recipientDoc.data().fcmToken;
    if (!fcmToken) return;

    try {
      await getMessaging().send({
        token: fcmToken,
        notification: {
          title: 'Calendar',
          body: randomMessage(),
        },
        android: {
          notification: {
            channelId: 'tn_calendar_chat',
            priority: 'high',
            sound: 'default',
          },
        },
        data: {
          chatId:   chatId,
          senderId: senderId,
        },
      });
    } catch (err) {
      if (
        err.code === 'messaging/invalid-registration-token' ||
        err.code === 'messaging/registration-token-not-registered'
      ) {
        await getFirestore()
          .collection('user_profiles')
          .doc(recipientId)
          .update({ fcmToken: null });
      }
    }
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
    ]);
  }
);
