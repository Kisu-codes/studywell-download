# Free FCM Server for StudyWell

This is a simple Node.js server that can be deployed to **free hosting services** to send FCM notifications.

## Free Hosting Options

### 1. Render (Recommended)
- **Free tier**: 750 hours/month
- **Setup**: 
  1. Go to https://render.com
  2. Create account
  3. New → Web Service
  4. Connect your GitHub repo (or deploy from this folder)
  5. Set environment variable: `FIREBASE_SERVICE_ACCOUNT` (your Firebase service account JSON)

### 2. Railway
- **Free tier**: $5 credit/month
- **Setup**: Similar to Render

### 3. Fly.io
- **Free tier**: 3 shared VMs
- **Setup**: Use Fly CLI

## Setup Steps

1. **Get Firebase Service Account Key**:
   - Go to Firebase Console → Project Settings → Service Accounts
   - Click "Generate New Private Key"
   - Save the JSON file

2. **Deploy to Free Hosting**:
   - Choose a hosting service (Render recommended)
   - Upload this server code
   - Set environment variable: `FIREBASE_SERVICE_ACCOUNT` = (paste the entire JSON as a string)

3. **Update Flutter App**:
   - Change the backend URL in `firebase_notification_service.dart`
   - Point to your free hosting URL

## Cost

**FREE** - All hosting services listed have free tiers that are sufficient for this use case.

## Note

This is a simplified version. For production, you'd want to:
- Add a database (MongoDB free tier, Supabase, etc.)
- Add authentication
- Add error handling
- Add logging

But for basic FCM notifications, this works!

