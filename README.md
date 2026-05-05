# 🏟️ STADIUM — Sports Venue Booking SaaS

A full-stack SaaS platform for sports venue management and booking, 
currently onboarding stadiums in Israel.

🌐 **Live Demo:** https://stadium-d5b5f.web.app

![Flutter](https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white)
![Firebase](https://img.shields.io/badge/Firebase-FFCA28?logo=firebase&logoColor=black)
![Dart](https://img.shields.io/badge/Dart-0175C2?logo=dart&logoColor=white)

## 🎯 Overview

STADIUM is an end-to-end booking platform that connects players with 
sports venue owners. Built as a multi-tenant SaaS, it serves both 
stadium administrators (with a full management dashboard) and players 
(with an intuitive booking experience).

**Status:** 3 stadiums onboarded, first paying customer in contract phase.

## 📱 Features

### For Players
- 🗓️ Real-time slot availability and booking
- 👥 Join friends with a 4-digit booking code
- 🔁 Recurring bookings (weekly games)
- 🔔 Push notifications for confirmations & cancellations
- 🌐 Hebrew & English support (full RTL)

### For Stadium Admins
- 📊 Analytics dashboard (revenue, occupancy, peak hours)
- 📑 Excel reports export
- 🏟️ Multi-stadium management
- 👤 Player & booking management
- 🛡️ Manual + automated booking flows

## 🛠️ Tech Stack

| Layer | Technology |
|-------|------------|
| Frontend | Flutter (Web, Android, iOS) |
| Backend | Firebase (Firestore, Auth, Hosting) |
| Notifications | Firebase Cloud Messaging |
| Security | Firestore Security Rules (multi-tenant) |
| Language | Dart |

## 🏗️ Architecture Highlights

- **Multi-tenant architecture** with isolated data per stadium
- **Real-time sync** via Firestore streams
- **Role-based access control** (Admin / Organizer / Player)
- **Bilingual UI** with full RTL support for Hebrew

## 📸 Screenshots

> *Screenshots coming soon — see live demo above.*

## 🚀 Getting Started

```bash
flutter pub get
flutter run
