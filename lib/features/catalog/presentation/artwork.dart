import 'package:flutter/material.dart';

import '../../../app/phosphor.dart';
import '../../../app/theme.dart';

class Artwork extends StatelessWidget {
  const Artwork(
    this.path, {
    super.key,
    this.backdrop = false,
    this.radius = 8,
    this.icon = PhosphorIconsRegular.filmSlate,
  });
  final String? path;
  final bool backdrop;
  final double radius;
  final IconData icon;

  static final _valid = RegExp(r'^/[A-Za-z0-9_.-]+\.(jpg|png|webp)$');

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: pressedColor,
      child: Center(child: Icon(icon, color: mutedColor)),
    );
    final value = path;
    return ClipRRect(
      borderRadius: BorderRadius.circular(backdrop ? 0 : radius),
      child: value != null && _valid.hasMatch(value)
          ? Image.network(
              'https://image.tmdb.org/t/p/${backdrop ? 'w780' : 'w342'}$value',
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              frameBuilder: (context, child, frame, sync) => sync
                  ? child
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: frame != null ? child : placeholder,
                    ),
              errorBuilder: (context, error, stack) => placeholder,
            )
          : placeholder,
    );
  }
}
