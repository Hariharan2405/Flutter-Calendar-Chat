const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');
const { logger } = require('firebase-functions');

initializeApp();

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
 * Fires when a new message is created in chats/{chatId}/messages/{messageId}.
 * Sends a random reminder notification instead of the real message content.
 */
/**
 * Fires when a new call document is created.
 * Sends a high-priority FCM data message to the callee so the app
 * wakes up even when killed and shows a full-screen incoming call UI.
 */
exports.onCallCreated = onDocumentCreated(
  'calls/{callId}',
  async (event) => {
    const callData = event.data.data();
    // Document is created with status:'calling'. 'ringing' is set later by the
    // callee's device — so we must fire on 'calling', not 'ringing'.
    if (callData.status !== 'calling') return;

    const calleeId = callData.calleeId;
    const callerId = callData.callerId;
    const callId = event.params.callId;
    const db = getFirestore();

    const [calleeDoc, callerDoc] = await Promise.all([
      db.collection('user_profiles').doc(calleeId).get(),
      db.collection('user_profiles').doc(callerId).get(),
    ]);
    if (!calleeDoc.exists) return;

    const fcmToken = calleeDoc.data().fcmToken;
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
          type: 'incoming_call',
          callId: callId,
          callerId: callerId,
          callerName: callerName,
          callType: callData.type,
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

exports.sendChatNotification = onDocumentCreated(
  'chats/{chatId}/messages/{messageId}',
  async (event) => {
    const message = event.data.data();
    const chatId = event.params.chatId;
    const senderId = message.senderId;

    if (!senderId) return;

    // Get the chat document to find both participants
    const chatDoc = await getFirestore().collection('chats').doc(chatId).get();
    if (!chatDoc.exists) return;

    const participants = chatDoc.data().participants;
    if (!participants || participants.length < 2) return;

    // The recipient is whoever is NOT the sender
    const recipientId = participants.find((uid) => uid !== senderId);
    if (!recipientId) return;

    // Get recipient's FCM token
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
          chatId: chatId,
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
