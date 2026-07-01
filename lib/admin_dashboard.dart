import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'main.dart'; // To reuse AppColors and UserProfile

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const AdminApp());
}

class AdminApp extends StatelessWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TRADING MASTER ADMIN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: AppColors.bg,
        primaryColor: AppColors.cyan,
      ),
      home: const AdminDashboard(),
    );
  }
}

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> _updateUser(UserProfile user, int newLimit, DateTime? newExpiry) async {
    await _db.collection('users').doc(user.uid).update({
      'dailyTradeLimit': newLimit,
      'subscriptionExpiry': newExpiry,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.card,
        title: const Text('Admin Dashboard - User Management'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _db.collection('users').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('Error: ${snapshot.error}'));
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final users = snapshot.data!.docs.map((doc) => UserProfile.fromFirestore(doc)).toList();

          return ListView.builder(
            padding: const EdgeInsets.all(20),
            itemCount: users.length,
            itemBuilder: (context, index) {
              final user = users[index];
              return Card(
                color: AppColors.card,
                margin: const EdgeInsets.only(bottom: 15),
                child: ListTile(
                  title: Text(user.displayName, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Email: ${user.email}'),
                      Text('Daily Limit: ${user.dailyTradeLimit} (Used: ${user.tradesUsedToday})'),
                      Text('Expiry: ${user.subscriptionExpiry?.toString() ?? 'Lifetime'}'),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, color: AppColors.cyan),
                        onPressed: () => _showEditDialog(user),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showEditDialog(UserProfile user) {
    final limitController = TextEditingController(text: user.dailyTradeLimit.toString());
    DateTime? selectedDate = user.subscriptionExpiry;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.card,
              title: Text('Manage ${user.displayName}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: limitController,
                    decoration: const InputDecoration(labelText: 'Daily Trade Limit'),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 20),
                  ListTile(
                    title: const Text('Subscription Expiry'),
                    subtitle: Text(selectedDate?.toString().split(' ')[0] ?? 'Lifetime'),
                    trailing: const Icon(Icons.calendar_today),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: selectedDate ?? DateTime.now(),
                        firstDate: DateTime.now(),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) {
                        setDialogState(() {
                          selectedDate = picked;
                        });
                      }
                    },
                  ),
                  TextButton(
                    onPressed: () => setDialogState(() => selectedDate = null),
                    child: const Text('Set as Lifetime', style: TextStyle(color: AppColors.red)),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await _updateUser(
                      user,
                      int.tryParse(limitController.text) ?? user.dailyTradeLimit,
                      selectedDate,
                    );
                    Navigator.pop(context);
                  },
                  child: const Text('Save Changes'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
