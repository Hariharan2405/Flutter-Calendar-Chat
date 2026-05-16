const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');

initializeApp();

const REMINDER_MESSAGES = [
  "Don't forget to note your expenses today! 💰",
  "Leave ahead, make a plan — check your calendar. 🗓️",
  "Small savings today, big dreams tomorrow. 📈",
  "Have you planned your week yet? Open TN Calendar! 📋",
  "A little note now saves a lot of confusion later. 📝",
  "Track your spending, control your future. 💡",
  "Your calendar is waiting — what's on for today? ☀️",
  "Don't let expenses pile up — log them now! 🧾",
  "Plan smart, live better. Open TN Calendar. 🌟",
  "A quick note a day keeps the budget on track. 🎯",
  "Check your Tamil Nadu holidays — plan your next break! 🎉",
  "Have you reviewed last month's expenses? 📊",
  "Stay organised, stay stress-free. 🧘",
  "New day, new plan — open your calendar! 🌅",
  "Every rupee counts — track it with TN Calendar. ₹",
];

function randomMessage() {
  return REMINDER_MESSAGES[Math.floor(Math.random() * REMINDER_MESSAGES.length)];
}

/**
 * Fires when a new message is created in chats/{chatId}/messages/{messageId}.
 * Sends a random reminder notification instead of the real message content.
 */
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
          title: 'TN Calendar',
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
