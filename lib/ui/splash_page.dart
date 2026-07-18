import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';


/// The Vesopa splash. Plays the brand video once, then hands over to the till.
///
/// The video is a flourish, not a gate: if it fails to decode, is missing, or
/// simply takes too long, the app moves on. A till that will not open because
/// an intro clip would not play is worse than no intro at all.
class SplashPage extends StatefulWidget {
  const SplashPage({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  VideoPlayerController? _controller;
  bool _finished = false;
  Timer? _failsafe;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // Whatever happens to the video, the till opens within this window.
    _failsafe = Timer(const Duration(seconds: 6), _finish);

    try {
      final controller =
          VideoPlayerController.asset('assets/brand/file.mp4');
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() => _controller = controller);
      await controller.setVolume(0);
      await controller.play();

      controller.addListener(() {
        final value = controller.value;
        if (value.position >= value.duration && value.duration > Duration.zero) {
          _finish();
        }
      });
    } catch (_) {
      // No video, no problem — go straight to the till.
      _finish();
    }
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _failsafe?.cancel();
    widget.onDone();
  }

  @override
  void dispose() {
    _failsafe?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;

    return Scaffold(
      // True black, not the chrome grey: the video is cut on black, and any
      // lighter backdrop shows as a visible frame around it.
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: ready
            // Fill the screen and crop the overflow, rather than letterboxing
            // the clip into a small rectangle in the middle.
            ? FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: controller.value.size.width,
                  height: controller.value.size.height,
                  child: VideoPlayer(controller),
                ),
              )
            // Shown while the video loads, and as the fallback if it never
            // does — so the screen is never just black.
            : Center(
                child: Image.asset(
                  'assets/brand/512x512.png',
                  width: 160,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
      ),
    );
  }
}
