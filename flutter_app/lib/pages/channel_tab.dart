import 'package:flutter/material.dart';

class ChannelTab extends StatelessWidget {
  const ChannelTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Channel')),
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.subscriptions_outlined, size: 64),
            SizedBox(height: 16),
            Text('YouTube channel login coming soon'),
          ],
        ),
      ),
    );
  }
}
