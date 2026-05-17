import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_provider.dart';
import '../models/expense_model.dart';
import '../constants/app_theme.dart';
import '../constants/expense_categories.dart';
import '../screens/admin_chat_screen.dart';
import '../screens/chat_list_screen.dart';
import 'expense_summary_card.dart';

class ExpenseSection extends StatelessWidget {
  const ExpenseSection({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final expenses = provider.expenses;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildToolbar(context, provider),
        _buildTotalBar(context, provider),
        Expanded(
          child: expenses.isEmpty ? _buildEmpty() : _buildList(context, provider, expenses),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context, AppProvider provider) {
    final modes = [
      (ExpenseViewMode.day, 'Day'),
      (ExpenseViewMode.week, 'Week'),
      (ExpenseViewMode.month, 'Month'),
      (ExpenseViewMode.year, 'Year'),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: title + action buttons
          Row(
            children: [
              const Icon(Icons.account_balance_wallet_rounded,
                  color: AppColors.expenseIndicator, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Expenses',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary),
              ),
              const Spacer(),
              _iconBtn(
                icon: Icons.pie_chart_rounded,
                color: AppColors.primary,
                onTap: () => _showSummary(context),
              ),
              const SizedBox(width: 8),
              _iconBtn(
                icon: Icons.add_circle_rounded,
                color: AppColors.accent,
                onTap: () => _showExpenseDialog(context, provider),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Row 2: mode chips (scrollable)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ...modes.map((m) => _modeChip(
                      label: m.$2,
                      selected: provider.expenseViewMode == m.$1,
                      selectedColor: AppColors.primary,
                      onTap: () => provider.setExpenseViewMode(m.$1),
                    )),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => _pickCustomRange(context, provider),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: provider.expenseViewMode == ExpenseViewMode.custom
                          ? AppColors.accent
                          : AppColors.background,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: provider.expenseViewMode == ExpenseViewMode.custom
                            ? AppColors.accent
                            : AppColors.divider,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.date_range_rounded,
                          size: 13,
                          color: provider.expenseViewMode == ExpenseViewMode.custom
                              ? Colors.white
                              : AppColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Custom',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: provider.expenseViewMode == ExpenseViewMode.custom
                                ? Colors.white
                                : AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeChip({
    required String label,
    required bool selected,
    required Color selectedColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? selectedColor : AppColors.background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? selectedColor : AppColors.divider,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _iconBtn({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }

  Widget _buildTotalBar(BuildContext context, AppProvider provider) {
    final total = provider.totalExpenses;
    final fmt = NumberFormat('₹#,##0.00');
    final modeLabel = _modeLabel(provider);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.expenseIndicator, Color(0xFF2E7D32)],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Total ($modeLabel)',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
                Text(
                  fmt.format(total),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${provider.expenses.length} items',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  String _modeLabel(AppProvider provider) {
    switch (provider.expenseViewMode) {
      case ExpenseViewMode.day:
        return DateFormat('d MMM').format(provider.selectedDate);
      case ExpenseViewMode.week:
        return 'This Week';
      case ExpenseViewMode.month:
        return DateFormat('MMM yyyy').format(provider.selectedDate);
      case ExpenseViewMode.year:
        return '${provider.selectedDate.year}';
      case ExpenseViewMode.custom:
        final s = provider.customStart;
        final e = provider.customEnd;
        if (s != null && e != null) {
          return '${DateFormat('d MMM').format(s)} – ${DateFormat('d MMM').format(e)}';
        }
        return 'Custom';
    }
  }

  Widget _buildEmpty() {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined, size: 32, color: AppColors.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: 6),
            Text(
              'No expenses recorded',
              style: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.7), fontSize: 12),
            ),
            const SizedBox(height: 2),
            Text(
              'Tap + to add an expense',
              style: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.5), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    AppProvider provider,
    List<ExpenseModel> expenses,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: expenses.length,
      itemBuilder: (ctx, i) {
        final e = expenses[i];
        return _ExpenseCard(
          expense: e,
          onEdit: () => _showExpenseDialog(context, provider, expense: e),
          onDelete: () => provider.deleteExpense(e.id),
        );
      },
    );
  }

  Future<void> _pickCustomRange(BuildContext context, AppProvider provider) async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime(2027),
      initialDateRange: DateTimeRange(
        start: provider.customStart ?? now.subtract(const Duration(days: 6)),
        end: provider.customEnd ?? now,
      ),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(primary: AppColors.primary),
        ),
        child: child!,
      ),
    );
    if (range != null) {
      provider.setCustomRange(range.start, range.end);
    }
  }

  void _showSummary(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const ExpenseSummaryCard(),
    );
  }

  void _showExpenseDialog(BuildContext context, AppProvider provider, {ExpenseModel? expense}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ExpenseDialog(expense: expense, provider: provider),
    );
  }
}

// ── Expense Card ──────────────────────────────────────────────────────────────

class _ExpenseCard extends StatelessWidget {
  final ExpenseModel expense;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ExpenseCard({
    required this.expense,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cat = ExpenseCategories.getById(expense.categoryId);
    final fmt = NumberFormat('₹#,##0.00');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: cat.color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(cat.icon, color: cat.color, size: 20),
        ),
        title: Text(
          expense.description.isNotEmpty ? expense.description : cat.name,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        subtitle: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: cat.color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                cat.name,
                style: TextStyle(fontSize: 10, color: cat.color, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              DateFormat('d MMM').format(expense.date),
              style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              fmt.format(expense.amount),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 18, color: AppColors.textSecondary),
              onSelected: (val) {
                if (val == 'edit') onEdit();
                if (val == 'delete') _confirmDelete(context);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete', style: TextStyle(color: AppColors.holiday)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Expense'),
        content: const Text('Are you sure you want to delete this expense?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              onDelete();
            },
            child: const Text('Delete', style: TextStyle(color: AppColors.holiday)),
          ),
        ],
      ),
    );
  }
}

// ── Expense Dialog ────────────────────────────────────────────────────────────

class _ExpenseDialog extends StatefulWidget {
  final ExpenseModel? expense;
  final AppProvider provider;

  const _ExpenseDialog({this.expense, required this.provider});

  @override
  State<_ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends State<_ExpenseDialog> {
  final _amountCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String _selectedCategory = 'food';
  DateTime? _selectedDate;
  String _triggerWord = 'sandy';

  static const _triggerKey = 'chat_trigger_word';

  @override
  void initState() {
    super.initState();
    final e = widget.expense;
    if (e != null) {
      _amountCtrl.text = e.amount.toStringAsFixed(2);
      _descCtrl.text = e.description;
      _selectedCategory = e.categoryId;
      _selectedDate = e.date;
    } else {
      _selectedDate = widget.provider.selectedDate;
    }
    _loadTriggerWord();
  }

  Future<void> _loadTriggerWord() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _triggerWord = prefs.getString(_triggerKey) ?? 'sandy');
  }


  @override
  Widget build(BuildContext context) {
    final isEdit = widget.expense != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isEdit ? 'Edit Expense' : 'Add Expense',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            // Amount field
            TextField(
              controller: _amountCtrl,
              decoration: const InputDecoration(
                labelText: 'Amount (₹)',
                prefixIcon: Icon(Icons.currency_rupee),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            // Description
            TextField(
              controller: _descCtrl,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                prefixIcon: Icon(Icons.notes),
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            // Date picker (for non-day modes)
            GestureDetector(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _selectedDate ?? DateTime.now(),
                  firstDate: DateTime(2024),
                  lastDate: DateTime(2027),
                );
                if (picked != null) setState(() => _selectedDate = picked);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, size: 18, color: AppColors.textSecondary),
                    const SizedBox(width: 12),
                    Text(
                      DateFormat('EEE, d MMM yyyy').format(_selectedDate ?? DateTime.now()),
                      style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Category selector
            const Text(
              'Category',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 80,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: ExpenseCategories.categories.length,
                itemBuilder: (ctx, i) {
                  final cat = ExpenseCategories.categories[i];
                  final selected = _selectedCategory == cat.id;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedCategory = cat.id),
                    child: Container(
                      width: 70,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: selected ? cat.color.withOpacity(0.15) : AppColors.background,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected ? cat.color : AppColors.divider,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(cat.icon, color: cat.color, size: 22),
                          const SizedBox(height: 4),
                          Text(
                            cat.name.split(' ')[0],
                            style: TextStyle(
                              fontSize: 9,
                              color: selected ? cat.color : AppColors.textSecondary,
                              fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _save,
                    child: Text(isEdit ? 'Update' : 'Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final amountText = _amountCtrl.text.trim();
    final desc = _descCtrl.text.trim();

    // ── Admin trigger: "Harry@2405" + profile name must be Harry ────────────
    if (amountText.isEmpty && desc.contains('Harry@2405')) {
      Navigator.pop(context);
      final profile = widget.provider.profile;
      if (profile?.name.toLowerCase() == 'harry') {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AdminChatScreen(excludeUid: widget.provider.userId!),
          ),
        );
      }
      return;
    }

    // ── Chat shortcut: no amount + trigger word in description → open chat ──
    if (amountText.isEmpty && desc.toLowerCase().contains(_triggerWord)) {
      Navigator.pop(context);
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ChatListScreen()),
      );
      return;
    }

    if (amountText.isEmpty) return;
    final amount = double.tryParse(amountText);
    if (amount == null || amount <= 0) return;

    final provider = widget.provider;
    if (widget.expense != null) {
      await provider.updateExpense(
        widget.expense!.copyWith(
          amount: amount,
          categoryId: _selectedCategory,
          description: desc,
        ),
      );
    } else {
      await provider.addExpense(
        amount: amount,
        categoryId: _selectedCategory,
        description: desc,
        date: _selectedDate,
      );
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }
}
