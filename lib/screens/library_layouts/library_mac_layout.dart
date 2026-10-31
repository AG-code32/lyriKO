import 'package:flutter/material.dart';

/// Desktop-only navigation sizing. No iPhone layout shares these dimensions.
class LibraryMacLayout extends StatelessWidget {
  const LibraryMacLayout({super.key, required this.tabs, required this.selected, required this.onSelect});
  final List<String> tabs;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => Row(children: [
    for (var i = 0; i < tabs.length; i++) ...[
      if (i > 0) const SizedBox(width: 10),
      ChoiceChip(label: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(tabs[i])),
        selected: selected == i, onSelected: (_) => onSelect(i)),
    ],
  ]);
}
