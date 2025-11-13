import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:convert';

// Top-level function to handle background messages
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('Handling background message: ${message.messageId}');
  print('Message data: ${message.data}');
  print('Message notification: ${message.notification?.title}');
  
  // Note: FCM automatically shows notifications when app is closed
  // This handler is mainly for logging and data processing
  // The notification payload from FCM will be displayed by the system
}

class FirebaseNotificationService {
  static final FirebaseNotificationService _instance =
      FirebaseNotificationService._internal();
  factory FirebaseNotificationService() => _instance;
  FirebaseNotificationService._internal();

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static FirebaseMessaging? _messaging;
  static String? _fcmToken;

  // Initialize Firebase Cloud Messaging and local notifications
  static Future<void> initialize() async {
    try {
      print('Initializing FirebaseNotificationService...');

      // Initialize timezone
      tz.initializeTimeZones();
      try {
        tz.setLocalLocation(tz.getLocation('Asia/Manila'));
      } catch (e) {
        print('Could not set timezone, using UTC: $e');
        tz.setLocalLocation(tz.UTC);
      }

      // Initialize Firebase Messaging
      _messaging = FirebaseMessaging.instance;

      // Request notification permissions
      await _requestPermissions();

      // Initialize local notifications (for scheduled reminders)
      await _initializeLocalNotifications();

      // Clean up past notifications (prevent them from firing when app opens)
      await _cancelPastNotifications();
      
      // Reschedule all reminders (this cancels past ones and schedules only future ones)
      await rescheduleAllReminders();

      // Set up FCM message handlers
      await _setupFCMHandlers();

      // Get FCM token
      await _getFCMToken();

      // Create notification channels
      await _createNotificationChannels();

      print('FirebaseNotificationService initialized successfully');
    } catch (e) {
      print('Error initializing FirebaseNotificationService: $e');
      // Don't rethrow - let the app continue without notifications
    }
  }

  // Request notification permissions
  static Future<void> _requestPermissions() async {
    try {
      // Request FCM permissions
      NotificationSettings settings = await _messaging!.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      print('FCM Permission status: ${settings.authorizationStatus}');

      // Request Android notification permissions
      await _notifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();

      // Request exact alarm permissions for Android 12+ (CRITICAL for notifications when app is closed)
      final androidPlugin = _notifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      
      if (androidPlugin != null) {
        // Request exact alarms permission
        final exactAlarmGranted = await androidPlugin.requestExactAlarmsPermission();
        print('Exact alarm permission granted: $exactAlarmGranted');
        
        // Check if exact alarms are allowed
        final canScheduleExact = await androidPlugin.canScheduleExactNotifications();
        print('Can schedule exact notifications: $canScheduleExact');
        
        if (canScheduleExact == false) {
          print('⚠️ CRITICAL: Exact alarms not allowed! Notifications will NOT work when app is closed.');
          print('⚠️ Go to: Settings → Apps → StudyWell → Alarms & reminders → Allow exact alarms');
        } else {
          print('✅ Exact alarms permission: GRANTED');
        }
      }
      
      // Request battery optimization exemption (critical for background notifications)
      await _requestBatteryOptimizationExemption();

      print('Notification permissions requested');
    } catch (e) {
      print('Error requesting permissions: $e');
    }
  }

  // Request battery optimization exemption
  static Future<void> _requestBatteryOptimizationExemption() async {
    try {
      const platform = MethodChannel('com.studywell.system_notifications/battery');
      await platform.invokeMethod('requestBatteryOptimizationExemption');
      print('Battery optimization exemption requested');
    } catch (e) {
      print('Could not request battery optimization exemption: $e');
      print('⚠️ Please manually disable battery optimization:');
      print('   Settings → Apps → StudyWell → Battery → Unrestricted');
    }
  }

  // Cancel all past notifications to prevent them from firing when app opens
  static Future<void> _cancelPastNotifications() async {
    try {
      final pending = await _notifications.pendingNotificationRequests();
      print('Checking ${pending.length} pending notifications on app start...');
      
      // Cancel ALL existing notifications to prevent past ones from firing
      // This is the safest approach - we'll reschedule only future ones
      for (var notification in pending) {
        // Cancel all study reminders (IDs 1000-1799) and break reminders (2000-2799)
        if ((notification.id >= 1000 && notification.id < 1800) || 
            (notification.id >= 2000 && notification.id < 2800)) {
          await _notifications.cancel(notification.id);
        }
      }
      
      print('✅ Cancelled all existing notifications to prevent past ones from firing');
      print('   Notifications will be rescheduled for future times only');
    } catch (e) {
      print('Error cancelling past notifications: $e');
    }
  }

  // Initialize local notifications
  static Future<void> _initializeLocalNotifications() async {
    try {
      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      const DarwinInitializationSettings iosSettings =
          DarwinInitializationSettings(
            requestAlertPermission: true,
            requestBadgePermission: true,
            requestSoundPermission: true,
          );

      const InitializationSettings settings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _notifications.initialize(
        settings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          print('Notification tapped: ${response.payload}');
        },
      );

      print('Local notifications initialized');
    } catch (e) {
      print('Error initializing local notifications: $e');
    }
  }

  // Set up FCM message handlers
  static Future<void> _setupFCMHandlers() async {
    try {
      // Handle foreground messages
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        print('Received foreground message: ${message.messageId}');
        _showLocalNotification(message);
      });

      // Handle notification taps when app is in background
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        print('Notification opened app: ${message.messageId}');
        print('Message data: ${message.data}');
      });

      // Set background message handler
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      // Check if app was opened from a notification
      RemoteMessage? initialMessage =
          await _messaging!.getInitialMessage();
      if (initialMessage != null) {
        print('App opened from notification: ${initialMessage.messageId}');
      }

      print('FCM handlers set up');
    } catch (e) {
      print('Error setting up FCM handlers: $e');
    }
  }

  // Show local notification from FCM message
  static Future<void> _showLocalNotification(RemoteMessage message) async {
    try {
      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        'fcm_notifications',
        'Firebase Notifications',
        channelDescription: 'Notifications from Firebase Cloud Messaging',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      const NotificationDetails details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notifications.show(
        message.hashCode,
        message.notification?.title ?? 'StudyWell',
        message.notification?.body ?? '',
        details,
        payload: jsonEncode(message.data),
      );
    } catch (e) {
      print('Error showing local notification: $e');
    }
  }

  // Get FCM token and sync to Firestore
  static Future<String?> _getFCMToken() async {
    try {
      _fcmToken = await _messaging!.getToken();
      print('FCM Token: $_fcmToken');

      // Save token to SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcm_token', _fcmToken ?? '');

      // Sync token to Firestore for backend FCM notifications
      await _syncFCMTokenToFirestore(_fcmToken);

      // Listen for token refresh
      _messaging!.onTokenRefresh.listen((newToken) {
        _fcmToken = newToken;
        print('FCM Token refreshed: $newToken');
        prefs.setString('fcm_token', newToken);
        _syncFCMTokenToFirestore(newToken);
      });

      return _fcmToken;
    } catch (e) {
      print('Error getting FCM token: $e');
      return null;
    }
  }

  // Sync FCM token to Firestore
  static Future<void> _syncFCMTokenToFirestore(String? token) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && token != null) {
        await FirebaseFirestore.instance
            .collection('notification_preferences')
            .doc(user.uid)
            .set({
          'fcmToken': token,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        print('FCM token synced to Firestore');
      }
    } catch (e) {
      print('Error syncing FCM token to Firestore: $e');
    }
  }

  // Get current FCM token
  static String? getFCMToken() => _fcmToken;

  // Create notification channels
  static Future<void> _createNotificationChannels() async {
    try {
      final androidPlugin = _notifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidPlugin != null) {
        // Study reminders channel - MAX importance for reliability
        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            'study_reminders',
            'Study Reminders',
            description: 'Daily study session reminders',
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
            enableLights: true,
            showBadge: true,
          ),
        );

        // Break reminders channel - HIGH importance for reliability
        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            'break_reminders',
            'Break Reminders',
            description: 'Daily break reminders',
            importance: Importance.high,
            playSound: true,
            enableVibration: true,
            enableLights: true,
            showBadge: true,
          ),
        );

        // FCM notifications channel
        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            'fcm_notifications',
            'Firebase Notifications',
            description: 'Notifications from Firebase Cloud Messaging',
            importance: Importance.high,
            playSound: true,
            enableVibration: true,
          ),
        );

        print('Notification channels created');
      }
    } catch (e) {
      print('Error creating notification channels: $e');
    }
  }

  // Schedule study reminder using local notifications AND FCM
  static Future<void> scheduleStudyReminder({
    required int hour,
    required int minute,
    String? customMessage,
    String frequency = 'daily',
    List<int>? customDays,
  }) async {
    try {
      print('📅 Scheduling study reminder for ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}');
      
      // Sync preferences to Firestore for FCM backend scheduling
      await _syncNotificationPreferencesToFirestore(
        hour: hour,
        minute: minute,
        customMessage: customMessage,
        frequency: frequency,
        customDays: customDays,
      );

      // Cancel all existing study reminders
      for (int day = 1; day <= 7; day++) {
        for (int week = 0; week < 8; week++) {
          await _notifications.cancel(1000 + day + (week * 100));
        }
      }

      // Determine which days to schedule based on frequency
      List<int> daysToSchedule = [];
      switch (frequency) {
        case 'daily':
          daysToSchedule = [1, 2, 3, 4, 5, 6, 7]; // All days
          break;
        case 'weekly':
          daysToSchedule = [1, 2, 3, 4, 5]; // Monday to Friday
          break;
        case 'custom':
          daysToSchedule = customDays ?? [1, 2, 3, 4, 5];
          break;
        default:
          daysToSchedule = [1, 2, 3, 4, 5, 6, 7]; // Default to daily
      }

      // Store notification data
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'study_reminder_data',
        jsonEncode({
          'hour': hour,
          'minute': minute,
          'customMessage': customMessage,
          'frequency': frequency,
          'customDays': customDays,
        }),
      );

      // Schedule notifications - schedule for next 8 weeks
      final now = DateTime.now();
      final location = tz.local;

      for (int day in daysToSchedule) {
        // Get the next occurrence of this day at the specified time
        var scheduledDate = _getNextScheduledDate(now, day, hour, minute);
        
        final timeUntil = scheduledDate.difference(now);
        print('📅 Day $day (${_getDayName(day)}): Next occurrence at ${scheduledDate.toString()}');
        print('   Time until: ${timeUntil.inHours}h ${timeUntil.inMinutes % 60}m ${timeUntil.inSeconds % 60}s');

        // Schedule for 8 weeks
        for (int week = 0; week < 8; week++) {
          final weekDate = scheduledDate.add(Duration(days: week * 7));
          
          // Skip if in the past
          if (weekDate.isBefore(now)) continue;
          
          final tzScheduledDate = tz.TZDateTime.from(weekDate, location);
          final notificationId = 1000 + day + (week * 100);

          const AndroidNotificationDetails androidDetails =
              AndroidNotificationDetails(
            'study_reminders',
            'Study Reminders',
            channelDescription: 'Daily study session reminders',
            importance: Importance.max,
            priority: Priority.max,
            showWhen: true,
            enableVibration: true,
            playSound: true,
            fullScreenIntent: true,
            category: AndroidNotificationCategory.alarm,
            visibility: NotificationVisibility.public,
            autoCancel: true,
          );

          const NotificationDetails details = NotificationDetails(
            android: androidDetails,
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          );

          try {
            // Check if notification is in the future
            if (weekDate.isAfter(now)) {
              final timeUntil = weekDate.difference(now);
              
              // ALWAYS schedule LOCAL notifications (works when app is OPEN)
              // This works for any time - Android can handle it when app is open
              await _notifications.zonedSchedule(
                notificationId,
                'Study Time! 📚',
                customMessage ?? 'Time to focus on your studies.',
                tzScheduledDate,
                details,
                androidScheduleMode: AndroidScheduleMode.exact, // Works when app is open
                uiLocalNotificationDateInterpretation:
                    UILocalNotificationDateInterpretation.absoluteTime,
                matchDateTimeComponents: null,
              );
              
              if (week == 0) {
                print('✅ Scheduled LOCAL reminder for ${weekDate.toString()}');
                print('   Time until notification: ${timeUntil.inHours}h ${timeUntil.inMinutes % 60}m ${timeUntil.inSeconds % 60}s');
                print('   Will fire at: ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}');
                print('   ✅ LOCAL notification scheduled (works when app is OPEN)');
                print('   ✅ FCM notification synced to Firestore (works when app is CLOSED)');
              }
            } else {
              // Skip past notifications
              if (week == 0) {
                print('⏭️ Skipping past notification: ${weekDate.toString()}');
              }
            }
          } catch (e) {
            print('Error scheduling: $e');
          }
        }
      }

      print('✅ Study reminders scheduled successfully');
      print('   Next notification will fire at the scheduled time');
    } catch (e) {
      print('Error scheduling study reminder: $e');
    }
  }

  // Schedule break reminder using local notifications
  static Future<void> scheduleBreakReminder({
    required int hour,
    required int minute,
    String? customMessage,
    String frequency = 'daily',
    List<int>? customDays,
  }) async {
    try {
      print(
        'Scheduling break reminder for $hour:$minute with frequency: $frequency',
      );

      // Cancel existing notifications
      await _notifications.cancel(2);

      // Determine which days to schedule based on frequency
      List<int> daysToSchedule = [];
      switch (frequency) {
        case 'daily':
          daysToSchedule = [1, 2, 3, 4, 5, 6, 7]; // All days
          break;
        case 'weekly':
          daysToSchedule = [1, 2, 3, 4, 5]; // Monday to Friday
          break;
        case 'custom':
          daysToSchedule = customDays ?? [1, 2, 3, 4, 5];
          break;
        default:
          daysToSchedule = [1, 2, 3, 4, 5, 6, 7]; // Default to daily
      }

      // Store notification data
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'break_reminder_data',
        jsonEncode({
          'hour': hour,
          'minute': minute,
          'customMessage': customMessage,
          'frequency': frequency,
          'customDays': customDays,
        }),
      );

      // Schedule notifications for each selected day
      // Schedule multiple weeks in advance for better reliability when app is closed
      final now = DateTime.now();
      final location = tz.local;
      const int weeksInAdvance = 8; // Schedule 8 weeks ahead

      for (int day in daysToSchedule) {
        // Calculate base date once (next occurrence of this day)
        var baseScheduledDate = _getNextScheduledDate(now, day, hour, minute);
        
        // Schedule for multiple weeks to ensure notifications work when app is closed
        for (int week = 0; week < weeksInAdvance; week++) {
          // Calculate date for this week (base date + weeks)
          var scheduledDate = baseScheduledDate.add(Duration(days: week * 7));
          
          // Skip if in the past
          if (scheduledDate.isBefore(now)) continue;

          final tzScheduledDate = tz.TZDateTime.from(scheduledDate, location);
          final notificationId = 2000 + day + (week * 100); // Unique ID per day and week

          const AndroidNotificationDetails androidDetails =
              AndroidNotificationDetails(
            'break_reminders',
            'Break Reminders',
            channelDescription: 'Daily break reminders',
            importance: Importance.high,
            priority: Priority.high,
            showWhen: true,
            enableVibration: true,
            playSound: true,
            category: AndroidNotificationCategory.reminder,
            visibility: NotificationVisibility.public,
          );

          const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          );

          const NotificationDetails details = NotificationDetails(
            android: androidDetails,
            iOS: iosDetails,
          );

          // Schedule individual notification
          try {
            final timeUntil = scheduledDate.difference(now);
            
            // ALWAYS schedule LOCAL notifications (works when app is OPEN)
            // This works for any time - Android can handle it when app is open
            await _notifications.zonedSchedule(
              notificationId,
              'Break Time! ☕',
              customMessage ??
                  'Take a well-deserved break. Rest helps improve learning.',
              tzScheduledDate,
              details,
              androidScheduleMode: AndroidScheduleMode.exact, // Works when app is open
              uiLocalNotificationDateInterpretation:
                  UILocalNotificationDateInterpretation.absoluteTime,
              payload: 'break_reminder',
            );
            
            if (week == 0) {
              print('✅ Scheduled LOCAL break reminder for day $day at ${scheduledDate.toString()}');
              print('   Time until notification: ${timeUntil.inHours}h ${timeUntil.inMinutes % 60}m ${timeUntil.inSeconds % 60}s');
              print('   ✅ LOCAL notification scheduled (works when app is OPEN)');
              print('   ✅ FCM notification synced to Firestore (works when app is CLOSED)');
            }
          } catch (e) {
            if (week == 0) {
              print('❌ Error scheduling break reminder for day $day: $e');
            }
            // Continue with next week even if one fails
          }
        }
      }

      print('Break reminders scheduled for days: $daysToSchedule');
    } catch (e) {
      print('Error scheduling break reminder: $e');
    }
  }

  // Get next scheduled date for a specific day of week
  static DateTime _getNextScheduledDate(
      DateTime now, int dayOfWeek, int hour, int minute) {
    // dayOfWeek: 1=Monday, 7=Sunday
    final currentDayOfWeek = now.weekday;
    
    // Create target time for today
    final targetTimeToday = DateTime(now.year, now.month, now.day, hour, minute);
    
    // If today is the target day
    if (currentDayOfWeek == dayOfWeek) {
      // If time hasn't passed today, schedule for today
      if (targetTimeToday.isAfter(now)) {
        print('   Today is the target day, time hasn\'t passed - scheduling for TODAY');
        return targetTimeToday;
      }
      // Time has passed, schedule for next week
      print('   Today is the target day, but time has passed - scheduling for NEXT WEEK');
      final nextWeek = now.add(const Duration(days: 7));
      return DateTime(nextWeek.year, nextWeek.month, nextWeek.day, hour, minute);
    }
    
    // Calculate days until target day
    int daysUntilTarget = (dayOfWeek - currentDayOfWeek) % 7;
    if (daysUntilTarget == 0) {
      daysUntilTarget = 7; // Next week
    }
    
    // Calculate the target date
    final targetDate = now.add(Duration(days: daysUntilTarget));
    final result = DateTime(targetDate.year, targetDate.month, targetDate.day, hour, minute);
    print('   Current day: $currentDayOfWeek, Target day: $dayOfWeek, Days until: $daysUntilTarget');
    return result;
  }

  // Helper to get day name
  static String _getDayName(int dayOfWeek) {
    const days = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    if (dayOfWeek >= 1 && dayOfWeek <= 7) {
      return days[dayOfWeek];
    }
    return 'Day$dayOfWeek';
  }

  // Cancel all reminders
  static Future<void> cancelAllReminders() async {
    try {
      // Cancel all study reminders (IDs 1001-1807 for 8 weeks)
      for (int day = 1; day <= 7; day++) {
        for (int week = 0; week < 8; week++) {
          await _notifications.cancel(1000 + day + (week * 100));
        }
      }

      // Cancel all break reminders (IDs 2001-2807 for 8 weeks)
      for (int day = 1; day <= 7; day++) {
        for (int week = 0; week < 8; week++) {
          await _notifications.cancel(2000 + day + (week * 100));
        }
      }

      // Also cancel legacy IDs
      await _notifications.cancel(1);
      await _notifications.cancel(2);

      // Clear stored data
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('study_reminder_data');
      await prefs.remove('break_reminder_data');

      // Cancel FCM scheduled notifications
      await _cancelFCMNotifications();

      print('All reminders cancelled (local + FCM)');
    } catch (e) {
      print('Error cancelling reminders: $e');
    }
  }

  // Reschedule all reminders
  static Future<void> rescheduleAllReminders() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Reschedule study reminder
      final studyData = prefs.getString('study_reminder_data');
      if (studyData != null) {
        final data = jsonDecode(studyData);
        await scheduleStudyReminder(
          hour: data['hour'],
          minute: data['minute'],
          customMessage: data['customMessage'],
          frequency: data['frequency'] ?? 'daily',
          customDays: data['customDays'] != null
              ? List<int>.from(data['customDays'])
              : null,
        );
      }

      // Reschedule break reminder
      final breakData = prefs.getString('break_reminder_data');
      if (breakData != null) {
        final data = jsonDecode(breakData);
        await scheduleBreakReminder(
          hour: data['hour'],
          minute: data['minute'],
          customMessage: data['customMessage'],
          frequency: data['frequency'] ?? 'daily',
          customDays: data['customDays'] != null
              ? List<int>.from(data['customDays'])
              : null,
        );
      }

      print('All reminders rescheduled');
    } catch (e) {
      print('Error rescheduling reminders: $e');
    }
  }

  // Get pending notifications
  static Future<List<PendingNotificationRequest>>
      getPendingNotifications() async {
    try {
      final pendingNotifications =
          await _notifications.pendingNotificationRequests();
      // Only log for debugging, not shown to user
      print('Pending notifications: ${pendingNotifications.length}');
      
      // Also check if exact alarms are allowed
      final androidPlugin = _notifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        final canScheduleExact = await androidPlugin.canScheduleExactNotifications();
        print('Can schedule exact notifications: $canScheduleExact');
        if (canScheduleExact == false) {
          print('⚠️ CRITICAL: Exact alarms not allowed! Notifications will NOT work when app is closed.');
        }
      }
      
      return pendingNotifications;
    } catch (e) {
      print('Error getting pending notifications: $e');
      return [];
    }
  }

  // Subscribe to a topic (for future use)
  static Future<void> subscribeToTopic(String topic) async {
    try {
      await _messaging?.subscribeToTopic(topic);
      print('Subscribed to topic: $topic');
    } catch (e) {
      print('Error subscribing to topic: $e');
    }
  }

  // Unsubscribe from a topic
  static Future<void> unsubscribeFromTopic(String topic) async {
    try {
      await _messaging?.unsubscribeFromTopic(topic);
      print('Unsubscribed from topic: $topic');
    } catch (e) {
      print('Error unsubscribing from topic: $e');
    }
  }

  // Sync notification preferences to Firestore for FCM backend
  static Future<void> _syncNotificationPreferencesToFirestore({
    required int hour,
    required int minute,
    String? customMessage,
    String frequency = 'daily',
    List<int>? customDays,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        print('❌ No user logged in, cannot sync preferences to Firestore');
        return;
      }

      print('📤 Syncing notification preferences to Firestore...');
      print('   User ID: ${user.uid}');
      print('   FCM Token: ${_fcmToken != null ? "✅ Present" : "❌ MISSING!"}');
      
      // If FCM token is missing, try to get it
      if (_fcmToken == null || _fcmToken!.isEmpty) {
        print('⚠️ FCM token missing, trying to get it...');
        _fcmToken = await _messaging?.getToken();
        if (_fcmToken == null) {
          print('❌ CRITICAL: FCM token is still null! Notifications will not work.');
          print('   Make sure Firebase Messaging is initialized properly.');
        } else {
          print('✅ FCM token retrieved: ${_fcmToken!.substring(0, 20)}...');
        }
      }

      final prefs = await SharedPreferences.getInstance();
      final studyRemindersEnabled = prefs.getBool('studywell_settings_study_reminders_enabled') ?? true;

      // Get device timezone offset in hours (e.g., +8 for UTC+8, -5 for UTC-5)
      final now = DateTime.now();
      final timezoneOffsetHours = now.timeZoneOffset.inHours;
      print('🌍 Device timezone offset: UTC${timezoneOffsetHours >= 0 ? '+' : ''}$timezoneOffsetHours');

      final dataToSave = {
        'userId': user.uid,
        'fcmToken': _fcmToken ?? '',
        'studyReminderHour': hour,
        'studyReminderMinute': minute,
        'customMessage': customMessage ?? 'Time to focus on your studies.',
        'studyReminderFrequency': frequency,
        'studyReminderDays': customDays ?? (frequency == 'daily' ? [1, 2, 3, 4, 5, 6, 7] : [1, 2, 3, 4, 5]),
        'studyRemindersEnabled': studyRemindersEnabled,
        'timezoneOffset': timezoneOffsetHours, // Store timezone offset (e.g., +8, -5)
        'updatedAt': FieldValue.serverTimestamp(),
      };

      print('📝 Saving to Firestore collection: notification_preferences');
      print('   Document ID: ${user.uid}');
      print('   Data: hour=$hour, minute=$minute, frequency=$frequency');

      await FirebaseFirestore.instance
          .collection('notification_preferences')
          .doc(user.uid)
          .set(dataToSave, SetOptions(merge: true));

      print('✅ Notification preferences synced to Firestore for FCM backend');
      print('   Collection: notification_preferences');
      print('   Document: ${user.uid}');
    } catch (e, stackTrace) {
      print('❌ Error syncing notification preferences to Firestore: $e');
      print('   Stack trace: $stackTrace');
      // Don't throw - local notifications will still work
    }
  }

  // Cancel FCM scheduled notifications
  static Future<void> _cancelFCMNotifications() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // Update preferences to disable notifications (triggers Cloud Function to cancel)
      await FirebaseFirestore.instance
          .collection('notification_preferences')
          .doc(user.uid)
          .set({
        'studyRemindersEnabled': false,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      print('FCM notifications cancelled');
    } catch (e) {
      print('Error cancelling FCM notifications: $e');
    }
  }

}

