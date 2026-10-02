import 'dart:math' as math;

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
      // Everything scales off the space the calendar is actually given, so it
      // fills a tablet (full-width or as a side pane) instead of leaving sparse
      // cells, and shrinks rather than overflowing when height is tight. A
      // phone in portrait lands on 1.0, so its layout is unchanged.
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 400 x 400 is the phone-sized baseline this layout was tuned for
          // (the content is ~380 tall at s = 1, so this leaves a little slack).
          final s = math
              .min(constraints.maxWidth / 400, constraints.maxHeight / 400)
              .clamp(0.85, 1.6)
              .toDouble();
          return Column(
            children: [
              _buildHeader(context, provider, s),
              _buildCalendar(context, provider, s),
              _buildHolidayBanner(provider, s),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppProvider provider, double s) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16 * s, 8 * s, 16 * s, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                DateFormat('MMMM yyyy').format(provider.focusedDate),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18 * s,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Tamil Nadu Calendar',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontSize: 12 * s,
                ),
              ),
            ],
          ),
          Row(
            children: [
              _legendDot(AppColors.holiday, 'Holiday', s),
              SizedBox(width: 12 * s),
              _legendDot(AppColors.noteIndicator, 'Note', s),
              SizedBox(width: 12 * s),
              _legendDot(AppColors.expenseIndicator, 'Expense', s),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label, double s) {
    return Row(
      children: [
        Container(
          width: 8 * s,
          height: 8 * s,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        SizedBox(width: 4 * s),
        Text(label,
            style: TextStyle(color: Colors.white70, fontSize: 10 * s)),
      ],
    );
  }

  Widget _buildCalendar(BuildContext context, AppProvider provider, double s) {
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
      daysOfWeekHeight: 28 * s,
      rowHeight: 44 * s,
      calendarStyle: CalendarStyle(
        outsideDaysVisible: false,
        defaultTextStyle: TextStyle(color: Colors.white, fontSize: 13 * s),
        weekendTextStyle: TextStyle(color: const Color(0xFFFFCDD2), fontSize: 13 * s),
        outsideTextStyle: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 13 * s),
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
        selectedTextStyle: TextStyle(
          color: AppColors.primary,
          fontWeight: FontWeight.bold,
          fontSize: 13 * s,
        ),
        todayDecoration: BoxDecoration(
          border: Border.all(color: Colors.white, width: 2),
          shape: BoxShape.circle,
        ),
        todayTextStyle: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 13 * s,
        ),
        markerDecoration: const BoxDecoration(
          color: Colors.transparent,
          shape: BoxShape.circle,
        ),
        markersMaxCount: 3,
        cellMargin: EdgeInsets.all(4 * s),
      ),
      daysOfWeekStyle: DaysOfWeekStyle(
        weekdayStyle: TextStyle(
          color: Colors.white70,
          fontSize: 12 * s,
          fontWeight: FontWeight.w600,
        ),
        weekendStyle: TextStyle(
          color: const Color(0xFFFFCDD2),
          fontSize: 12 * s,
          fontWeight: FontWeight.w600,
        ),
      ),
      calendarBuilders: CalendarBuilders(
        defaultBuilder: (ctx, day, focusedDay) => _buildDay(ctx, day, provider, false, s),
        todayBuilder: (ctx, day, focusedDay) => _buildDay(ctx, day, provider, false, s, isToday: true),
        selectedBuilder: (ctx, day, focusedDay) => _buildDay(ctx, day, provider, true, s),
      ),
    );
  }

  Widget _buildDay(
    BuildContext context,
    DateTime day,
    AppProvider provider,
    bool isSelected,
    double s, {
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
        width: 36 * s,
        height: 36 * s,
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
                    fontSize: 13 * s,
                    height: 1,
                  ),
                ),
              ),
              // Indicator dots at the bottom
              if (hasIndicators)
                Positioned(
                  bottom: 4 * s,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasNote)
                        Container(
                          width: 4 * s,
                          height: 4 * s,
                          margin: EdgeInsets.symmetric(horizontal: 1 * s),
                          decoration: const BoxDecoration(
                            color: AppColors.noteIndicator,
                            shape: BoxShape.circle,
                          ),
                        ),
                      if (hasExpense)
                        Container(
                          width: 4 * s,
                          height: 4 * s,
                          margin: EdgeInsets.symmetric(horizontal: 1 * s),
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

  Widget _buildHolidayBanner(AppProvider provider, double s) {
    final holidays = TamilNaduHolidays.getHolidaysForDate(provider.selectedDate);
    if (holidays.isEmpty) return SizedBox(height: 8 * s);

    return Container(
      margin: EdgeInsets.fromLTRB(12 * s, 4 * s, 12 * s, 8 * s),
      padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 6 * s),
      decoration: BoxDecoration(
        color: AppColors.holiday.withOpacity(0.2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.holiday.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.celebration, color: Colors.white, size: 14 * s),
          SizedBox(width: 6 * s),
          Expanded(
            child: Text(
              holidays.map((h) => h.name).join(' • '),
              style: TextStyle(color: Colors.white, fontSize: 11 * s, fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
