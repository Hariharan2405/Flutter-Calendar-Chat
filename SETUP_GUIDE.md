# TN Calendar App — Setup Guide

## Step 1: Install Flutter

If not already installed:
- Download from https://flutter.dev/docs/get-started/install/windows
- Add Flutter to your PATH

Verify: `flutter doctor`

---

## Step 2: Install FlutterFire CLI

```bash
dart pub global activate flutterfire_cli
```

---

## Step 3: Set up Firebase Project

1. Go to https://console.firebase.google.com
2. Create a new project (or use your existing one)
3. **Enable Authentication:**
   - Authentication → Sign-in method → Anonymous → Enable
4. **Enable Firestore:**
   - Firestore Database → Create database → Start in production mode
   - Choose a region close to India (e.g., `asia-south1`)
5. **Apply Firestore security rules** (from `firestore.rules` in this project)

---

## Step 4: Connect Firebase to the App

Run in the project root directory:
```bash
flutterfire configure
```

This auto-generates `lib/firebase_options.dart` with your real config.

Then add the Android app:
- Package name: `com.example.calendar_app`
- Download `google-services.json` → place in `android/app/google-services.json`

---

## Step 5: Install Dependencies

```bash
flutter pub get
```

---

## Step 6: Run the App

```bash
# Android (connect device or start emulator first)
flutter run

# Web (no extra setup needed)
flutter run -d chrome
```

---

## Firestore Indexes

If you see "index required" errors, create these composite indexes in Firebase Console → Firestore → Indexes:

| Collection | Fields | Order |
|-----------|--------|-------|
| notes | dateKey ASC, createdAt DESC | |
| expenses | dateKey ASC, createdAt DESC | |
| expenses | date ASC, date DESC | |

Or deploy via CLI:
```bash
firebase deploy --only firestore:indexes
```

---

## Free Tier Usage

Your Blaze (pay-as-you-go) plan includes these **always-free** quotas:
- Firestore: 50,000 reads/day, 20,000 writes/day, 1 GiB storage
- Auth: Unlimited anonymous users

For a personal calendar app this will cost **₹0**.

---

## App Features

| Feature | Description |
|---------|-------------|
| Calendar | Full month view with Tamil Nadu holidays highlighted |
| Holidays | 2024–2026 TN government holidays (national + state) |
| Notes | Add/edit/delete notes per date |
| Expenses | Track daily expenses with 10 categories |
| Expense Views | Day / Week / Month / Year / Custom date range |
| Summary | Pie chart + category breakdown with percentages |
| Indicators | Dots on calendar dates that have notes or expenses |
| Offline | Firebase SDK caches data for offline access |
