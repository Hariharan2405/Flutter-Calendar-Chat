import 'package:flutter/material.dart';

class ExpenseCategory {
  final String id;
  final String name;
  final IconData icon;
  final Color color;

  const ExpenseCategory({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
  });
}

class ExpenseCategories {
  static final List<ExpenseCategory> categories = [
    const ExpenseCategory(
      id: 'food',
      name: 'Food & Dining',
      icon: Icons.restaurant,
      color: Color(0xFFE53935),
    ),
    const ExpenseCategory(
      id: 'transport',
      name: 'Transportation',
      icon: Icons.directions_bus,
      color: Color(0xFF8E24AA),
    ),
    const ExpenseCategory(
      id: 'shopping',
      name: 'Shopping',
      icon: Icons.shopping_bag,
      color: Color(0xFF1E88E5),
    ),
    const ExpenseCategory(
      id: 'entertainment',
      name: 'Entertainment',
      icon: Icons.movie,
      color: Color(0xFF00ACC1),
    ),
    const ExpenseCategory(
      id: 'health',
      name: 'Healthcare',
      icon: Icons.local_hospital,
      color: Color(0xFF43A047),
    ),
    const ExpenseCategory(
      id: 'utilities',
      name: 'Utilities',
      icon: Icons.bolt,
      color: Color(0xFFFFB300),
    ),
    const ExpenseCategory(
      id: 'education',
      name: 'Education',
      icon: Icons.school,
      color: Color(0xFFFF6B35),
    ),
    const ExpenseCategory(
      id: 'housing',
      name: 'Housing',
      icon: Icons.home,
      color: Color(0xFF6D4C41),
    ),
    const ExpenseCategory(
      id: 'personal',
      name: 'Personal Care',
      icon: Icons.face,
      color: Color(0xFF546E7A),
    ),
    const ExpenseCategory(
      id: 'snacks',
      name: 'Snacks & Cool Drinks',
      icon: Icons.local_cafe,
      color: Color(0xFFF4511E),
    ),
    const ExpenseCategory(
      id: 'online_food',
      name: 'Online Food',
      icon: Icons.delivery_dining,
      color: Color(0xFF039BE5),
    ),
    const ExpenseCategory(
      id: 'others',
      name: 'Others',
      icon: Icons.more_horiz,
      color: Color(0xFF00897B),
    ),
  ];

  static ExpenseCategory getById(String id) {
    return categories.firstWhere(
      (c) => c.id == id,
      orElse: () => categories.last,
    );
  }

  static ExpenseCategory getByName(String name) {
    return categories.firstWhere(
      (c) => c.name == name,
      orElse: () => categories.last,
    );
  }
}
