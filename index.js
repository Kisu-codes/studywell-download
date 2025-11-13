// Free FCM Notification Server for StudyWell
// Deploy to Render (free tier) - no credit card needed!

const express = require('express');
const admin = require('firebase-admin');
const cron = require('node-cron');

const app = express();
app.use(express.json());

// Initialize Firebase Admin
let firebaseInitialized = false;
let db = null;

function initializeFirebase() {
  if (firebaseInitialized) return;
  
  try {
    // Get service account from environment variable
    const serviceAccountJson = process.env.FIREBASE_SERVICE_ACCOUNT;
    
    if (!serviceAccountJson) {
      console.log('⚠️ FIREBASE_SERVICE_ACCOUNT not set.');
      console.log('   Get it from: Firebase Console → Project Settings → Service Accounts');
      console.log('   Then set it as environment variable in Render');
      return;
    }
    
    const serviceAccount = JSON.parse(serviceAccountJson);
    
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount)
    });
    
    db = admin.firestore();
    firebaseInitialized = true;
    console.log('✅ Firebase Admin initialized');
  } catch (error) {
    console.error('❌ Error initializing Firebase:', error.message);
  }
}

// Health check
app.get('/', (req, res) => {
  res.json({ 
    status: 'ok', 
    service: 'StudyWell FCM Server',
    firebaseInitialized,
    timestamp: new Date().toISOString()
  });
});

// Listen to Firestore changes and schedule notifications
async function watchNotificationPreferences() {
  if (!firebaseInitialized) return;
  
  try {
    console.log('👂 Watching notification_preferences collection...');
    
    // Watch for changes in notification_preferences
    db.collection('notification_preferences').onSnapshot((snapshot) => {
      snapshot.docChanges().forEach(async (change) => {
        const userId = change.doc.id;
        const data = change.doc.data();
        
        if (change.type === 'added' || change.type === 'modified') {
          console.log(`📝 Notification preferences updated for user ${userId}`);
          
          // Cancel existing scheduled notifications
          await cancelAllScheduledNotifications(userId);
          
          // If notifications are enabled, schedule new ones
          if (data.studyRemindersEnabled && data.fcmToken) {
            await scheduleStudyReminders(userId, data);
          }
        } else if (change.type === 'removed') {
          console.log(`🗑️ Notification preferences removed for user ${userId}`);
          await cancelAllScheduledNotifications(userId);
        }
      });
    }, (error) => {
      console.error('❌ Error watching Firestore:', error);
    });
  } catch (error) {
    console.error('❌ Error setting up Firestore listener:', error);
  }
}

// Schedule study reminders
async function scheduleStudyReminders(userId, preferences) {
  if (!firebaseInitialized) return;
  
  try {
    const hour = preferences.studyReminderHour || 9;
    const minute = preferences.studyReminderMinute || 0;
    const frequency = preferences.studyReminderFrequency || 'daily';
    const customDays = preferences.studyReminderDays || [];
    const customMessage = preferences.customMessage || 'Time to focus on your studies.';
    const fcmToken = preferences.fcmToken;

    if (!fcmToken) {
      console.log(`⚠️ No FCM token for user ${userId}`);
      return;
    }

    // Determine which days to schedule
    let daysToSchedule = [];
    switch (frequency) {
      case 'daily':
        daysToSchedule = [1, 2, 3, 4, 5, 6, 7];
        break;
      case 'weekly':
        daysToSchedule = [1, 2, 3, 4, 5];
        break;
      case 'custom':
        daysToSchedule = customDays.length > 0 ? customDays : [1, 2, 3, 4, 5];
        break;
      default:
        daysToSchedule = [1, 2, 3, 4, 5, 6, 7];
    }

    const now = new Date();
    let scheduledCount = 0;

    // Schedule for next 8 weeks
    for (let week = 0; week < 8; week++) {
      for (const dayOfWeek of daysToSchedule) {
        const scheduledDate = getNextScheduledDate(now, dayOfWeek, hour, minute, week);
        
        if (scheduledDate <= now) continue;

        const notificationId = `study_${userId}_${dayOfWeek}_${week}`;
        
        // Store in Firestore
        await db.collection('scheduled_notifications').doc(notificationId).set({
          userId: userId,
          fcmToken: fcmToken,
          scheduledFor: admin.firestore.Timestamp.fromDate(scheduledDate),
          hour: hour,
          minute: minute,
          dayOfWeek: dayOfWeek,
          week: week,
          title: 'Study Time! 📚',
          message: customMessage,
          type: 'study_reminder',
          sent: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        
        scheduledCount++;
      }
    }

    console.log(`✅ Scheduled ${scheduledCount} notifications for user ${userId}`);
  } catch (error) {
    console.error(`❌ Error scheduling notifications for user ${userId}:`, error);
  }
}

// Get next scheduled date
function getNextScheduledDate(now, dayOfWeek, hour, minute, weekOffset = 0) {
  const currentDayOfWeek = now.getDay() === 0 ? 7 : now.getDay();
  const targetTimeToday = new Date(now);
  targetTimeToday.setHours(hour, minute, 0, 0);
  
  if (currentDayOfWeek === dayOfWeek) {
    if (targetTimeToday > now) {
      const result = new Date(targetTimeToday);
      result.setDate(result.getDate() + (weekOffset * 7));
      return result;
    }
    const nextWeek = new Date(now);
    nextWeek.setDate(nextWeek.getDate() + 7 + (weekOffset * 7));
    nextWeek.setHours(hour, minute, 0, 0);
    return nextWeek;
  }
  
  let daysUntilTarget = (dayOfWeek - currentDayOfWeek + 7) % 7;
  if (daysUntilTarget === 0) daysUntilTarget = 7;
  
  const targetDate = new Date(now);
  targetDate.setDate(targetDate.getDate() + daysUntilTarget + (weekOffset * 7));
  targetDate.setHours(hour, minute, 0, 0);
  return targetDate;
}

// Cancel all scheduled notifications
async function cancelAllScheduledNotifications(userId) {
  if (!firebaseInitialized) return;
  
  try {
    const snapshot = await db.collection('scheduled_notifications')
      .where('userId', '==', userId)
      .where('sent', '==', false)
      .get();
    
    const batch = db.batch();
    snapshot.docs.forEach(doc => {
      batch.delete(doc.ref);
    });
    
    await batch.commit();
    console.log(`✅ Cancelled ${snapshot.size} notifications for user ${userId}`);
  } catch (error) {
    console.error(`❌ Error cancelling notifications:`, error);
  }
}

// Send FCM notification
async function sendFCMNotification(notification, notificationId) {
  if (!firebaseInitialized) return;
  
  try {
    const message = {
      token: notification.fcmToken,
      notification: {
        title: notification.title,
        body: notification.message,
      },
      data: {
        type: notification.type || 'study_reminder',
        userId: notification.userId,
      },
      android: {
        priority: 'high',
        notification: {
          channelId: 'study_reminders',
          sound: 'default',
          priority: 'max',
        },
      },
    };

    const response = await admin.messaging().send(message);
    console.log(`✅ Sent notification ${notificationId}: ${response}`);
    
    // Mark as sent
    await db.collection('scheduled_notifications').doc(notificationId).update({
      sent: true,
      sentAt: admin.firestore.FieldValue.serverTimestamp(),
      messageId: response,
    });
    
    return response;
  } catch (error) {
    console.error(`❌ Error sending notification ${notificationId}:`, error);
    
    // If token is invalid, mark as sent
    if (error.code === 'messaging/invalid-registration-token' || 
        error.code === 'messaging/registration-token-not-registered') {
      await db.collection('scheduled_notifications').doc(notificationId).update({
        sent: true,
        error: error.message,
      });
    }
  }
}

// Cron job: Check for due notifications every minute
cron.schedule('* * * * *', async () => {
  if (!firebaseInitialized) return;
  
  try {
    const now = admin.firestore.Timestamp.now();
    const oneMinuteFromNow = admin.firestore.Timestamp.fromMillis(now.toMillis() + 60000);
    
    const snapshot = await db.collection('scheduled_notifications')
      .where('sent', '==', false)
      .where('scheduledFor', '>=', now)
      .where('scheduledFor', '<=', oneMinuteFromNow)
      .limit(100)
      .get();
    
    if (snapshot.size > 0) {
      console.log(`📤 Found ${snapshot.size} notifications to send`);
    }
    
    snapshot.forEach(async (doc) => {
      const notification = doc.data();
      await sendFCMNotification(notification, doc.id);
    });
  } catch (error) {
    console.error('❌ Error in cron job:', error);
  }
});

// Cleanup old notifications (runs daily at midnight)
cron.schedule('0 0 * * *', async () => {
  if (!firebaseInitialized) return;
  
  try {
    const oneWeekAgo = admin.firestore.Timestamp.fromMillis(Date.now() - 7 * 24 * 60 * 60 * 1000);
    
    const snapshot = await db.collection('scheduled_notifications')
      .where('sent', '==', true)
      .where('sentAt', '<', oneWeekAgo)
      .limit(500)
      .get();
    
    const batch = db.batch();
    snapshot.docs.forEach(doc => {
      batch.delete(doc.ref);
    });
    
    await batch.commit();
    console.log(`🧹 Cleaned up ${snapshot.size} old notifications`);
  } catch (error) {
    console.error('❌ Error cleaning up:', error);
  }
});

// Start server
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`🚀 StudyWell FCM Server running on port ${PORT}`);
  initializeFirebase();
  
  // Start watching Firestore after a short delay
  setTimeout(() => {
    if (firebaseInitialized) {
      watchNotificationPreferences();
    }
  }, 2000);
});
