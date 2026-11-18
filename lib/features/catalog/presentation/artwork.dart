import 'package:flutter/material.dart';

import '../../../app/theme.dart';

class Artwork extends StatelessWidget {
  const Artwork(this.path, {super.key, this.backdrop = false});
  final String? path;
  final bool backdrop;

  @override
  Widget build(BuildContext context) {
    const placeholder = ColoredBox(
      color: Color(0xff2b292d),
      child: Center(
        child: Icon(Icons.local_movies_outlined, color: mutedColor),
      ),
    );
    final value = path;
    final valid =
        value != null &&
        RegExp(r'^/[A-Za-z0-9_.-]+\.(jpg|png|webp)$').hasMatch(value);
    return ClipRRect(
      borderRadius: BorderRadius.circular(backdrop ? 0 : 4),
      child: valid
          ? Image.network(
              'https://image.tmdb.org/t/p/${backdrop ? 'w780' : 'w342'}$value',
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              frameBuilder: (context, child, frame, sync) =>
                  sync || frame != null ? child : placeholder,
              errorBuilder: (context, error, stack) => placeholder,
            )
          : placeholder,
    );
  }
}
