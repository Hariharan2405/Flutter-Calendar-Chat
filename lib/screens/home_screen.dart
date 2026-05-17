import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../providers/app_provider.dart';
import '../services/chat_service.dart';
import '../constants/app_theme.dart';
import '../widgets/calendar_widget.dart';
import '../widgets/notes_section.dart';
import '../widgets/expense_section.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  bool _profileDialogShown = false;
  final ChatService _chatService = ChatService();

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  void _maybeShowProfileSetup(AppProvider provider) {
    if (!provider.isLoading && !provider.profileReady && !_profileDialogShown) {
      _profileDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showProfileSetup(provider);
      });
    }
  }

  Future<void> _showProfileSetup(AppProvider provider) async {
    final nameCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool passVisible = false;
    bool confirmVisible = false;
    String? error;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.person_rounded, color: AppColors.primary, size: 28),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Create Your Profile',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Set up once. Your notes and expenses will be saved to your profile.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Your name',
                    prefixIcon: Icon(Icons.badge_rounded),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: passCtrl,
                  obscureText: !passVisible,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(passVisible
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded),
                      onPressed: () => setLocal(() => passVisible = !passVisible),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: confirmCtrl,
                  obscureText: !confirmVisible,
                  decoration: InputDecoration(
                    labelText: 'Confirm password',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(confirmVisible
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded),
                      onPressed: () => setLocal(() => confirmVisible = !confirmVisible),
                    ),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                ],
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    final pass = passCtrl.text;
                    final confirm = confirmCtrl.text;
                    if (name.isEmpty) {
                      setLocal(() => error = 'Please enter your name.');
                      return;
                    }
                    if (pass.length < 4) {
                      setLocal(() => error = 'Password must be at least 4 characters.');
                      return;
                    }
                    if (pass != confirm) {
                      setLocal(() => error = 'Passwords do not match.');
                      return;
                    }
                    final existing = await _chatService.findProfileByName(name);
                    if (existing != null) {
                      if (existing.password != pass) {
                        setLocal(() => error = 'Incorrect password for this name.');
                        return;
                      }
                      // Name + password match → login without creating a duplicate
                      await provider.loginWithExistingProfile(existing);
                      if (ctx.mounted) Navigator.pop(ctx);
                      return;
                    }
                    await provider.createProfile(name, pass);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Save Profile', style: TextStyle(fontSize: 15)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();

    _maybeShowProfileSetup(provider);

    if (provider.isLoading) {
      return const Scaffold(
        backgroundColor: AppColors.primary,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text('Connecting to Firebase...', style: TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
        ),
      );
    }

    if (provider.errorMessage != null) {
      return Scaffold(
        backgroundColor: AppColors.primary,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.cloud_off_rounded, color: Colors.white, size: 64),
                const SizedBox(height: 24),
                const Text(
                  'Firebase Setup Required',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    provider.errorMessage!,
                    style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.6),
                    textAlign: TextAlign.left,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Go to console.firebase.google.com\n'
                    '→ Authentication → Sign-in method\n'
                    '→ Enable "Anonymous"\n\n'
                    'Also create a Firestore database if\nyou haven\'t already.',
                    style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.6),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () => provider.retryInitialize(),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
          children: [
            // ── Top half: Calendar ─────────────────────────────────────────
            SizedBox(
              height: constraints.maxHeight * 0.48,
              child: const CalendarWidget(),
            ),

            // ── Bottom half: Notes + Expenses ─────────────────────────────
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(0)),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.cardShadow,
                      blurRadius: 10,
                      offset: Offset(0, -4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Tab bar
                    Container(
                      color: AppColors.surface,
                      child: TabBar(
                        controller: _tabCtrl,
                        tabs: [
                          Tab(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.sticky_note_2_rounded, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  'Notes',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: _tabCtrl.index == 0
                                        ? FontWeight.w700
                                        : FontWeight.normal,
                                  ),
                                ),
                                if (provider.notesForSelectedDate.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    width: 18,
                                    height: 18,
                                    decoration: const BoxDecoration(
                                      color: AppColors.noteIndicator,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Center(
                                      child: Text(
                                        '${provider.notesForSelectedDate.length}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Tab(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.account_balance_wallet_rounded, size: 16),
                                const SizedBox(width: 6),
                                const Text(
                                  'Expenses',
                                  style: TextStyle(fontSize: 13),
                                ),
                                if (provider.expenses.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppColors.expenseIndicator,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      NumberFormat.compactCurrency(
                                        symbol: '₹',
                                        decimalDigits: 0,
                                      ).format(provider.totalExpenses),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                        labelColor: AppColors.primary,
                        unselectedLabelColor: AppColors.textSecondary,
                        indicatorColor: AppColors.primary,
                        dividerColor: AppColors.divider,
                      ),
                    ),

                    // Tab views
                    Expanded(
                      child: TabBarView(
                        controller: _tabCtrl,
                        children: const [
                          NotesSection(),
                          ExpenseSection(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }
}
