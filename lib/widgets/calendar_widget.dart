import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:intl/intl.dart';
import '../providers/app_provider.dart';
import '../constants/tamil_nadu_holidays.dart';
import '../constants/app_theme.dart';
import '../models/note_model.dart';

class CalendarWidget extends StatelessWidget {
  const CalendarWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, AppColors.primaryLight],
        ),
      ),
      child: Column(
        children: [
          _buildHeader(context, provider),
          _buildCalendar(context, provider),
          _buildHolidayBanner(provider),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppProvider provider) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                DateFormat('MMMM yyyy').format(provider.focusedDate),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Tamil Nadu Calendar',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontSize: 12,
                ),
              ),
            ],
          ),
          Row(
            children: [
              _legendDot(AppColors.holiday, 'Holiday'),
              const SizedBox(width: 12),
              _legendDot(AppColors.noteIndicator, 'Note'),
              const SizedBox(width: 12),
              _legendDot(AppColors.expenseIndicator, 'Expense'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10)),
      ],
    );
  }

  Widget _buildCalendar(BuildContext context, AppProvider provider) {
    return TableCalendar(
      firstDay: DateTime(2024, 1, 1),
      lastDay: DateTime(2027, 12, 31),
      focusedDay: provider.focusedDate,
      selectedDayPredicate: (day) => isSameDay(day, provider.selectedDate),
      onDaySelected: (selected, focused) {
        provider.selectDate(selected);
        provider.setFocusedDate(focused);
      },
      onPageChanged: (focused) => provider.setFocusedDate(focused),
      calendarFormat: CalendarFormat.month,
      headerVisible: false,
      daysOfWeekHeight: 28,
      rowHeight: 44,
      calendarStyle: CalendarStyle(
        outsideDaysVisible: false,
        defaultTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        weekendTextStyle: const TextStyle(color: Color(0xFFFFCDD2), fontSize: 13),
        outsideTextStyle: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 13),
        selectedDecoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        selectedTextStyle: const TextStyle(
          color: AppColors.primary,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
        todayDecoration: BoxDecoration(
          border: Border.all(color: Colors.white, width: 2),
          shape: BoxShape.circle,
        ),
        todayTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
        markerDecoration: const BoxDecoration(
          color: Colors.transparent,
          shape: BoxShape.circle,
        ),
        markersMaxCount: 3,
        cellMargin: const EdgeInsets.all(4),
      ),
      daysOfWeekStyle: DaysOfWeekStyle(
        weekdayStyle: const TextStyle(
          color: Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        weekendStyle: const TextStyle(
          color: Color(0xFFFFCDD2),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      calendarBuilders: CalendarBuilders(
        defaultBuilder: (ctx, day, focusedDay) => _buildDay(ctx, day, provider, false),
        todayBuilder: (ctx, day, focusedDay) => _buildDay(ctx, day, provider, false, isToday: true),
        selectedBuilder: (ctx, day, focusedDay) => _buildDay(ctx, day, provider, true),
      ),
    );
  }

  Widget _buildDay(
    BuildContext context,
    DateTime day,
    AppProvider provider,
    bool isSelected, {
    bool isToday = false,
  }) {
    final isHoliday = TamilNaduHolidays.isHoliday(day);
    final dateKey = NoteModel.dateToKey(day);
    final hasNote = provider.datesWithNotes.contains(dateKey);
    final hasExpense = provider.datesWithExpenses.contains(dateKey);

    final textColor = isSelected
        ? AppColors.primary
        : isHoliday
            ? AppColors.holiday
            : day.weekday == DateTime.saturday || day.weekday == DateTime.sunday
                ? const Color(0xFFFFCDD2)
                : Colors.white;

    final hasIndicators = hasNote || hasExpense;

    return Center(
      child: SizedBox(
        width: 36,
        height: 36,
        child: Container(
          decoration: isSelected
              ? BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                )
              : isToday
                  ? BoxDecoration(
                      border: Border.all(color: Colors.white, width: 2),
                      shape: BoxShape.circle,
                    )
                  : isHoliday
                      ? BoxDecoration(
                          color: AppColors.holiday.withValues(alpha: 0.25),
                          shape: BoxShape.circle,
                        )
                      : null,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Number — shift up slightly when dots are shown
              Align(
                alignment: hasIndicators
                    ? const Alignment(0, -0.2)
                    : Alignment.center,
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    color: textColor,
                    fontWeight: isSelected || isToday
                        ? FontWeight.bold
                        : FontWeight.normal,
                    fontSize: 13,
                    height: 1,
                  ),
                ),
              ),
              // Indicator dots at the bottom
              if (hasIndicators)
                Positioned(
                  bottom: 4,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasNote)
                        Container(
                          width: 4,
                          height: 4,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: const BoxDecoration(
                            color: AppColors.noteIndicator,
                            shape: BoxShape.circle,
                          ),
                        ),
                      if (hasExpense)
                        Container(
                          width: 4,
                          height: 4,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: const BoxDecoration(
                            color: AppColors.expenseIndicator,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHolidayBanner(AppProvider provider) {
    final holidays = TamilNaduHolidays.getHolidaysForDate(provider.selectedDate);
    if (holidays.isEmpty) return const SizedBox(height: 8);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.holiday.withOpacity(0.2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.holiday.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.celebration, color: Colors.white, size: 14),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              holidays.map((h) => h.name).join(' • '),
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
