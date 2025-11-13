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

// Manual trigger endpoint to test scheduling (for debugging)
app.post('/trigger-schedule/:userId', async (req, res) => {
  if (!firebaseInitialized) {
    return res.status(500).json({ error: 'Firebase not initialized' });
  }
  
  try {
    const userId = req.params.userId;
    const doc = await db.collection('notification_preferences').doc(userId).get();
    
    if (!doc.exists) {
      return res.status(404).json({ error: 'User preferences not found' });
    }
    
    const data = doc.data();
    console.log(`🔧 Manual trigger: Scheduling for user ${userId}`);
    await cancelAllScheduledNotifications(userId);
    
    if (data.studyRemindersEnabled && data.fcmToken) {
      await scheduleStudyReminders(userId, data);
      res.json({ 
        success: true, 
        message: `Scheduled notifications for user ${userId}` 
      });
    } else {
      res.json({ 
        success: false, 
        message: 'Notifications disabled or no FCM token' 
      });
    }
  } catch (error) {
    console.error('❌ Error in manual trigger:', error);
    res.status(500).json({ error: error.message });
  }
});

// Listen to Firestore changes and schedule notifications
async function watchNotificationPreferences() {
  if (!firebaseInitialized) {
    console.log('❌ Cannot watch Firestore: Firebase not initialized');
    return;
  }
  
  try {
    console.log('👂 Setting up Firestore listener for notification_preferences collection...');
    
    // Watch for changes in notification_preferences
    db.collection('notification_preferences').onSnapshot((snapshot) => {
      console.log(`📊 Firestore snapshot received: ${snapshot.size} documents`);
      
      snapshot.docChanges().forEach(async (change) => {
        const userId = change.doc.id;
        const data = change.doc.data();
        
        console.log(`📝 Change detected: type=${change.type}, userId=${userId}`);
        console.log(`   Data: enabled=${data.studyRemindersEnabled}, hasToken=${!!data.fcmToken}`);
        
        if (change.type === 'added' || change.type === 'modified') {
          console.log(`📝 Notification preferences updated for user ${userId}`);
          
          // Cancel existing scheduled notifications
          await cancelAllScheduledNotifications(userId);
          
          // If notifications are enabled, schedule new ones
          if (data.studyRemindersEnabled && data.fcmToken) {
            console.log(`✅ Scheduling notifications for user ${userId}`);
            await scheduleStudyReminders(userId, data);
          } else {
            console.log(`⚠️ Not scheduling: enabled=${data.studyRemindersEnabled}, hasToken=${!!data.fcmToken}`);
          }
        } else if (change.type === 'removed') {
          console.log(`🗑️ Notification preferences removed for user ${userId}`);
          await cancelAllScheduledNotifications(userId);
        }
      });
    }, (error) => {
      console.error('❌ Error watching Firestore:', error);
      console.error('   Stack:', error.stack);
    });
    
    console.log('✅ Firestore listener set up successfully');
  } catch (error) {
    console.error('❌ Error setting up Firestore listener:', error);
    console.error('   Stack:', error.stack);
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
    // Convert Flutter's day format (0=Sunday, 1=Monday, ..., 6=Saturday) 
    // to server format (1=Monday, 2=Tuesday, ..., 7=Sunday)
    const convertDayFormat = (day) => {
      if (day === 0) return 7; // Sunday: 0 -> 7
      return day; // Monday-Saturday: 1-6 -> 1-6
    };
    
    let daysToSchedule = [];
    switch (frequency) {
      case 'daily':
        daysToSchedule = [1, 2, 3, 4, 5, 6, 7];
        break;
      case 'weekly':
        daysToSchedule = [1, 2, 3, 4, 5];
        break;
      case 'custom':
        // Convert custom days from Flutter format (0-6) to server format (1-7)
        daysToSchedule = customDays.length > 0 
          ? customDays.map(convertDayFormat) 
          : [1, 2, 3, 4, 5];
        break;
      default:
        daysToSchedule = [1, 2, 3, 4, 5, 6, 7];
    }

    // Use UTC time to avoid timezone issues
    const now = new Date();
    let scheduledCount = 0;
    let skippedCount = 0;
    let errorCount = 0;

    console.log(`📅 Scheduling for user ${userId}:`);
    console.log(`   Hour: ${hour}, Minute: ${minute}`);
    console.log(`   Frequency: ${frequency}`);
    console.log(`   Days to schedule: ${JSON.stringify(daysToSchedule)}`);
    console.log(`   Current time (UTC): ${now.toISOString()}`);
    console.log(`   Current time (local): ${now.toString()}`);

    // Schedule for next 8 weeks
    for (let week = 0; week < 8; week++) {
      for (const dayOfWeek of daysToSchedule) {
        try {
          const scheduledDate = getNextScheduledDate(now, dayOfWeek, hour, minute, week);
          
          console.log(`   🔍 Date calculation: dayOfWeek=${dayOfWeek}, week=${week}, now=${now.toISOString()}, scheduled=${scheduledDate.toISOString()}`);
          
          if (scheduledDate <= now) {
            skippedCount++;
            console.log(`   ⏭️ Skipping past date: ${scheduledDate.toISOString()}`);
            continue;
          }

          const notificationId = `study_${userId}_${dayOfWeek}_${week}`;
          
          console.log(`   📝 Creating notification: ${notificationId}`);
          console.log(`      Scheduled for: ${scheduledDate.toISOString()}`);
          
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
          
          console.log(`   ✅ Created notification: ${notificationId}`);
          scheduledCount++;
        } catch (error) {
          errorCount++;
          console.error(`   ❌ Error creating notification for day ${dayOfWeek}, week ${week}:`, error);
          console.error(`      Stack:`, error.stack);
        }
      }
    }

    console.log(`✅ Scheduling complete for user ${userId}:`);
    console.log(`   Created: ${scheduledCount}`);
    console.log(`   Skipped (past dates): ${skippedCount}`);
    console.log(`   Errors: ${errorCount}`);
  } catch (error) {
    console.error(`❌ Error scheduling notifications for user ${userId}:`, error);
    console.error(`   Stack:`, error.stack);
  }
}

// Get next scheduled date
// Note: hour and minute are in user's local timezone (UTC+8 for Philippines)
// We need to convert to UTC for storage in Firestore
function getNextScheduledDate(now, dayOfWeek, hour, minute, weekOffset = 0) {
  // Create a copy of now to avoid mutating the original
  const currentDate = new Date(now);
  const currentDayOfWeek = currentDate.getDay() === 0 ? 7 : currentDate.getDay();
  
  // User is in UTC+8 (Philippines timezone)
  // Convert user's local time to UTC by subtracting 8 hours
  const utcHour = (hour - 8 + 24) % 24; // Subtract 8 hours, handle negative
  
  console.log(`   🌍 Timezone conversion: ${hour}:${minute} UTC+8 → ${utcHour}:${minute} UTC`);
  
  // Calculate target date in UTC
  let targetDate = new Date(currentDate);
  targetDate.setUTCHours(utcHour, minute, 0, 0);
  targetDate.setUTCSeconds(0);
  targetDate.setUTCMilliseconds(0);
  
  console.log(`   📅 After UTC conversion: ${targetDate.toISOString()} (should display as ${hour}:${minute} in UTC+8)`);
  
  // If same day of week
  if (currentDayOfWeek === dayOfWeek) {
    // If target time today is in the future, use it (with week offset)
    if (targetDate > currentDate) {
      targetDate.setUTCDate(targetDate.getUTCDate() + (weekOffset * 7));
      return targetDate;
    }
    // Otherwise, schedule for next week (with week offset)
    targetDate.setUTCDate(targetDate.getUTCDate() + 7 + (weekOffset * 7));
    return targetDate;
  }
  
  // Calculate days until target day of week
  let daysUntilTarget = (dayOfWeek - currentDayOfWeek + 7) % 7;
  if (daysUntilTarget === 0) daysUntilTarget = 7;
  
  // Add days until target + week offset (using UTC to maintain consistency)
  targetDate.setUTCDate(targetDate.getUTCDate() + daysUntilTarget + (weekOffset * 7));
  
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
console.log('⏰ Setting up cron job to run every minute...');
cron.schedule('* * * * *', async () => {
  const cronStartTime = new Date().toISOString();
  console.log(`⏰ [${cronStartTime}] Cron job triggered`);
  
  if (!firebaseInitialized) {
    console.log('⏰ Cron job skipped: Firebase not initialized');
    return;
  }
  
  try {
    const now = admin.firestore.Timestamp.now();
    const oneMinuteFromNow = admin.firestore.Timestamp.fromMillis(now.toMillis() + 60000);
    
    console.log(`⏰ Checking for notifications due between ${now.toDate().toISOString()} and ${oneMinuteFromNow.toDate().toISOString()}`);
    
    // Query only by sent=false to avoid complex index requirements
    // Filter in code for time range
    const snapshot = await db.collection('scheduled_notifications')
      .where('sent', '==', false)
      .limit(500) // Get up to 500 unsent notifications
      .get();
    
    console.log(`⏰ Cron job running: Found ${snapshot.size} unsent notifications total`);
    
    // Filter in code for notifications that are due now or in the next minute
    const dueNotifications = snapshot.docs.filter(doc => {
      const data = doc.data();
      const scheduledFor = data.scheduledFor;
      if (!scheduledFor) return false;
      return scheduledFor >= now && scheduledFor <= oneMinuteFromNow;
    });
    
    // Log details about first few notifications for debugging
    if (snapshot.size > 0 && snapshot.size <= 10) {
      snapshot.docs.slice(0, 3).forEach(doc => {
        const data = doc.data();
        const scheduledFor = data.scheduledFor;
        if (scheduledFor) {
          console.log(`   📋 Sample: ${doc.id} scheduled for ${scheduledFor.toDate().toISOString()}`);
        }
      });
    }
    
    if (dueNotifications.length > 0) {
      console.log(`📤 Found ${dueNotifications.length} notifications to send NOW`);
    } else {
      console.log(`   ℹ️ No notifications due in the next minute`);
    }
    
    for (const doc of dueNotifications) {
      const notification = doc.data();
      await sendFCMNotification(notification, doc.id);
    }
  } catch (error) {
    console.error('❌ Error in cron job:', error);
    console.error('   Stack:', error.stack);
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

// Heartbeat to show server is alive
setInterval(() => {
  const now = new Date().toISOString();
  console.log(`💓 Server heartbeat: ${now} | Firebase: ${firebaseInitialized ? '✅' : '❌'}`);
}, 60000); // Every minute

// Start server
const PORT = process.env.PORT || 3000;
console.log(`🔧 Starting server on port ${PORT}...`);
console.log(`🔧 Environment check: PORT=${PORT}, FIREBASE_SERVICE_ACCOUNT=${process.env.FIREBASE_SERVICE_ACCOUNT ? 'SET' : 'NOT SET'}`);

app.listen(PORT, () => {
  console.log(`🚀 StudyWell FCM Server running on port ${PORT}`);
  console.log(`📅 Server started at: ${new Date().toISOString()}`);
  
  initializeFirebase();
  
  // Start watching Firestore after a short delay
  setTimeout(() => {
    console.log(`⏰ Checking Firebase initialization status...`);
    if (firebaseInitialized) {
      console.log(`✅ Firebase initialized, starting Firestore watcher...`);
      watchNotificationPreferences();
    } else {
      console.log(`❌ Firebase not initialized, cannot start Firestore watcher`);
      console.log(`   Please check FIREBASE_SERVICE_ACCOUNT environment variable`);
    }
  }, 2000);
});
