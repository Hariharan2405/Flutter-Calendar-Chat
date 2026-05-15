const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');

initializeApp();

/**
 * Fires when a new message is created in chats/{chatId}/messages/{messageId}.
 * Sends an FCM push to the recipient so they get notified even when the app
 * is in the background or killed.
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

    // Get sender's display name (description) for the notification body
    const senderDoc = await getFirestore()
      .collection('user_profiles')
      .doc(senderId)
      .get();
    const senderName = senderDoc.exists
      ? (senderDoc.data().description ?? senderDoc.data().name ?? 'Someone')
      : 'Someone';

    // Get recipient's FCM token
    const recipientDoc = await getFirestore()
      .collection('user_profiles')
      .doc(recipientId)
      .get();
    if (!recipientDoc.exists) return;

    const fcmToken = recipientDoc.data().fcmToken;
    if (!fcmToken) return;

    // Build notification body
    const isVoice = message.type === 'voice';
    const body = isVoice
      ? `${senderName} sent a voice message`
      : `${senderName}: ${message.text ?? 'New message'}`;

    try {
      await getMessaging().send({
        token: fcmToken,
        notification: {
          title: 'TN Calendar',
          body: body,
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
      // Token may be stale — remove it so we don't retry with a dead token
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
