import 'package:flutter/material.dart';
import '../constants/app_theme.dart';

class StickerPickerSheet extends StatefulWidget {
  const StickerPickerSheet({super.key});

  @override
  State<StickerPickerSheet> createState() => _StickerPickerSheetState();
}

class _StickerPickerSheetState extends State<StickerPickerSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;

  static const _categories = [
    _StickerCategory(label: 'Faces', icon: Icons.tag_faces_rounded, stickers: [
      '😀', '😂', '😍', '🥰', '😎', '🤩', '😭', '😤',
      '🥺', '😱', '🤣', '😇', '🙃', '🤔', '😏', '🥳',
      '😴', '🤯', '🤗', '😬', '😌', '🤭', '🙄', '😅',
      '😆', '😋', '🤪', '😜', '😝', '🤑', '🤠', '😷',
    ]),
    _StickerCategory(label: 'Hands', icon: Icons.back_hand_rounded, stickers: [
      '👍', '👎', '👋', '🤝', '👏', '🙌', '🤜', '🤛',
      '✌️', '🤞', '🫶', '❤️‍🔥', '💪', '🫂', '🤙', '👌',
      '✋', '🖐️', '🤚', '🖖', '☝️', '👆', '👇', '👉',
    ]),
    _StickerCategory(label: 'Hearts', icon: Icons.favorite_rounded, stickers: [
      '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍',
      '💕', '💞', '💓', '💗', '💖', '💘', '💝', '💟',
      '❣️', '🫀', '💌', '💋', '😘', '🥰', '😻', '💑',
    ]),
    _StickerCategory(label: 'Animals', icon: Icons.pets_rounded, stickers: [
      '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼',
      '🐨', '🐯', '🦁', '🐸', '🐵', '🦋', '🐧', '🦅',
      '🐬', '🦄', '🐙', '🐢', '🦎', '🦀', '🐠', '🦓',
    ]),
    _StickerCategory(label: 'Food', icon: Icons.restaurant_rounded, stickers: [
      '🍕', '🍔', '🌮', '🍜', '🍣', '🍦', '🎂', '🍩',
      '☕', '🧋', '🍺', '🥤', '🍎', '🍓', '🍑', '🥑',
      '🍫', '🍿', '🥞', '🧁', '🍰', '🥂', '🍾', '🥘',
    ]),
    _StickerCategory(label: 'Fun', icon: Icons.celebration_rounded, stickers: [
      '🎉', '🎊', '🎈', '🎁', '🏆', '🥇', '🎯', '🎮',
      '🎸', '🎵', '🎶', '🌈', '⭐', '🌟', '✨', '🔥',
      '💥', '🎆', '🎇', '🪄', '🎭', '🃏', '🎲', '🧨',
    ]),
    _StickerCategory(label: 'Travel', icon: Icons.flight_rounded, stickers: [
      '✈️', '🚀', '🚂', '🚗', '🛵', '🚢', '🏖️', '🏔️',
      '🗺️', '🧳', '📸', '🌍', '🌏', '🌐', '🗼', '🏰',
      '⛩️', '🏝️', '🗽', '🌅', '🌄', '🌠', '🎑', '🏕️',
    ]),
    _StickerCategory(label: 'Sports', icon: Icons.sports_soccer_rounded, stickers: [
      '⚽', '🏀', '🏏', '🎾', '🏐', '🏈', '🎱', '🏓',
      '🥊', '🏋️', '🤸', '⛹️', '🤾', '🏊', '🚴', '🧘',
      '🥋', '🏇', '🎿', '🏂', '🪂', '🏄', '🤽', '🧗',
    ]),
    _StickerCategory(label: 'Nature', icon: Icons.eco_rounded, stickers: [
      '🌸', '🌺', '🌻', '🌹', '🌷', '🌿', '🍀', '🌱',
      '🍃', '🍂', '🍁', '🌲', '🌳', '🌴', '🎋', '🎍',
      '🌊', '⛈️', '🌈', '❄️', '☀️', '🌙', '⭐', '🌊',
    ]),
    _StickerCategory(label: 'Objects', icon: Icons.lightbulb_rounded, stickers: [
      '💡', '📱', '💻', '⌚', '📷', '🎧', '📚', '✏️',
      '🔑', '💎', '👑', '🎀', '🧸', '🪆', '🪅', '🎭',
      '💼', '🎒', '👜', '👗', '👟', '🕶️', '🎩', '💍',
    ]),
  ];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _categories.length, vsync: this, animationDuration: Duration.zero);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.52,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          TabBar(
            controller: _tabCtrl,
            isScrollable: true,
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.primary,
            indicatorSize: TabBarIndicatorSize.label,
            tabs: _categories
                .map((c) => Tab(icon: Icon(c.icon, size: 22)))
                .toList(),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: _categories
                  .map((cat) => GridView.builder(
                        padding: const EdgeInsets.all(8),
                        // Extent-based so the sheet gains columns as it widens
                        // on a tablet instead of scaling tiles up.
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 68,
                          mainAxisSpacing: 4,
                          crossAxisSpacing: 4,
                        ),
                        itemCount: cat.stickers.length,
                        itemBuilder: (ctx, i) => GestureDetector(
                          onTap: () =>
                              Navigator.pop(context, cat.stickers[i]),
                          child: Center(
                            child: Text(
                              cat.stickers[i],
                              style: const TextStyle(fontSize: 32),
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }
}

class _StickerCategory {
  final String label;
  final IconData icon;
  final List<String> stickers;
  const _StickerCategory(
      {required this.label, required this.icon, required this.stickers});
}
