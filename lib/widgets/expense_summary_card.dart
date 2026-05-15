import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../providers/app_provider.dart';
import '../constants/app_theme.dart';
import '../constants/expense_categories.dart';

class ExpenseSummaryCard extends StatefulWidget {
  const ExpenseSummaryCard({super.key});

  @override
  State<ExpenseSummaryCard> createState() => _ExpenseSummaryCardState();
}

class _ExpenseSummaryCardState extends State<ExpenseSummaryCard>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  int _touchedIndex = -1;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final summary = provider.categoryBreakdown;
    final total = provider.totalExpenses;
    final fmt = NumberFormat('₹#,##0.00');

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
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
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                const Icon(Icons.analytics_rounded, color: AppColors.primary, size: 22),
                const SizedBox(width: 8),
                const Text(
                  'Expense Summary',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  fmt.format(total),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.expenseIndicator,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TabBar(
            controller: _tabCtrl,
            tabs: const [
              Tab(text: 'Pie Chart'),
              Tab(text: 'Category List'),
            ],
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.primary,
          ),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                _buildPieChart(summary, total),
                _buildCategoryList(summary, total, fmt),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPieChart(List summary, double total) {
    if (summary.isEmpty) {
      return Center(
        child: Text(
          'No data to display',
          style: TextStyle(color: AppColors.textSecondary.withOpacity(0.7)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: PieChart(
              PieChartData(
                pieTouchData: PieTouchData(
                  touchCallback: (event, response) {
                    setState(() {
                      if (!event.isInterestedForInteractions ||
                          response == null ||
                          response.touchedSection == null) {
                        _touchedIndex = -1;
                        return;
                      }
                      _touchedIndex = response.touchedSection!.touchedSectionIndex;
                    });
                  },
                ),
                sections: List.generate(summary.length, (i) {
                  final s = summary[i];
                  final cat = ExpenseCategories.getById(s.categoryId);
                  final percentage = total > 0 ? (s.total / total * 100) : 0.0;
                  final isTouched = i == _touchedIndex;
                  return PieChartSectionData(
                    value: s.total,
                    color: cat.color,
                    radius: isTouched ? 70 : 55,
                    title: '${percentage.toStringAsFixed(1)}%',
                    titleStyle: TextStyle(
                      fontSize: isTouched ? 13 : 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  );
                }),
                centerSpaceRadius: 40,
                sectionsSpace: 2,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(summary.length, (i) {
                final s = summary[i];
                final cat = ExpenseCategories.getById(s.categoryId);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: cat.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          cat.name.split(' ')[0],
                          style: const TextStyle(fontSize: 11, color: AppColors.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryList(List summary, double total, NumberFormat fmt) {
    if (summary.isEmpty) {
      return Center(
        child: Text(
          'No expenses recorded',
          style: TextStyle(color: AppColors.textSecondary.withOpacity(0.7)),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: summary.length,
      itemBuilder: (ctx, i) {
        final s = summary[i];
        final cat = ExpenseCategories.getById(s.categoryId);
        final percentage = total > 0 ? (s.total / total) : 0.0;

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: cat.color.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(cat.icon, color: cat.color, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cat.name,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          '${s.count} transaction${s.count == 1 ? '' : 's'}',
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    fmt.format(s.total),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: percentage,
                  backgroundColor: cat.color.withOpacity(0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(cat.color),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${(percentage * 100).toStringAsFixed(1)}% of total',
                style: TextStyle(
                  fontSize: 10,
                  color: cat.color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }
}
