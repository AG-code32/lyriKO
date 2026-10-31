import 'package:flutter/material.dart';

/// Phone-only layout: compact tabs, independent of macOS dimensions.
class LibraryIosLayout extends StatelessWidget {
  const LibraryIosLayout({super.key, required this.tabs, required this.selected, required this.onSelect});
  final List<String> tabs;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => SizedBox(height: 48,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: tabs.length,
      separatorBuilder: (_, __) => const SizedBox(width: 6),
      itemBuilder: (context, i) => ChoiceChip(
        label: Text(tabs[i], style: const TextStyle(fontSize: 12)),
        selected: i == selected,
        onSelected: (_) => onSelect(i),
      ),
    ),
  );
}
