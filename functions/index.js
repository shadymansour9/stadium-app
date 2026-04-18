const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();

// שולח הודעה כשיש הזמנה חדשה
exports.onNewBooking = functions.firestore
  .document("bookings/{bookingId}")
  .onCreate(async (snap, context) => {
    const booking = snap.data();
    const userId = booking.userId;

    // קבל את ה-FCM token של המשתמש
    const userDoc = await admin.firestore().collection("users").doc(userId).get();
    const token = userDoc.data()?.fcmToken;
    if (!token) return;

    await admin.messaging().send({
      token: token,
      notification: {
        title: "Booking Confirmed ✅",
        body: `Your booking at ${booking.stadiumName} on ${booking.day} ${booking.date} • ${booking.time}`,
      },
    });
  });

// שולח הודעה כשמישהו מצטרף
exports.onPlayerJoined = functions.firestore
  .document("bookings/{bookingId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();

    const beforePlayers = before.players || [];
    const afterPlayers = after.players || [];

    if (afterPlayers.length <= beforePlayers.length) return;

    const newPlayer = afterPlayers[afterPlayers.length - 1];
    const organizerId = after.userId;

    const userDoc = await admin.firestore().collection("users").doc(organizerId).get();
    const token = userDoc.data()?.fcmToken;
    if (!token) return;

    await admin.messaging().send({
      token: token,
      notification: {
        title: "New player joined! 👥",
        body: `${newPlayer} joined your game at ${after.stadiumName}`,
      },
    });
  });