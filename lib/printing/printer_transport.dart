import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

/// How a printer is reached. Both are supported because a venue may have a
/// modern networked kitchen printer and a legacy till printer wired to a COM
/// port at the same counter.
enum PrinterKind { network, serial }

class PrinterConfig {
  const PrinterConfig({
    required this.id,
    required this.name,
    required this.kind,
    this.host,
    this.port = 9100,
    this.serialPort,
    this.baudRate = 9600,
  });

  final String id;
  final String name;
  final PrinterKind kind;

  /// Network printers.
  final String? host;
  final int port;

  /// Serial printers: the device path (COM3 on Windows, /dev/tty.* on macOS).
  final String? serialPort;
  final int baudRate;
}

/// Sends raw ESC/POS bytes to a printer.
abstract class PrinterTransport {
  Future<void> send(List<int> bytes);

  factory PrinterTransport.of(PrinterConfig config) {
    switch (config.kind) {
      case PrinterKind.network:
        return _NetworkTransport(config);
      case PrinterKind.serial:
        return _SerialTransport(config);
    }
  }
}

/// Raw TCP on port 9100 — the standard for networked thermal printers, and the
/// only path that works on iOS and Android tablets.
class _NetworkTransport implements PrinterTransport {
  _NetworkTransport(this.config);

  final PrinterConfig config;

  @override
  Future<void> send(List<int> bytes) async {
    final socket = await Socket.connect(
      config.host,
      config.port,
      timeout: const Duration(seconds: 5),
    );
    try {
      socket.add(bytes);
      await socket.flush();
    } finally {
      socket.destroy();
    }
  }
}

/// Serial/COM. Desktop only: iOS has no serial API at all, and Android needs
/// USB-host support that most tablets do not expose. Attempting it elsewhere
/// fails loudly rather than silently dropping the receipt.
class _SerialTransport implements PrinterTransport {
  _SerialTransport(this.config);

  final PrinterConfig config;

  @override
  Future<void> send(List<int> bytes) async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      throw UnsupportedError(
        'Serial printing is not available on this platform. '
        'Use a network printer instead.',
      );
    }

    final port = SerialPort(config.serialPort!);
    if (!port.openWrite()) {
      throw StateError('Could not open ${config.serialPort}.');
    }

    try {
      port.config = SerialPortConfig()
        ..baudRate = config.baudRate
        ..bits = 8
        ..stopBits = 1
        ..parity = SerialPortParity.none;

      port.write(Uint8List.fromList(bytes));
      port.drain();
    } finally {
      port.close();
      port.dispose();
    }
  }
}

/// Available serial ports, for the printer setup screen.
List<String> availableSerialPorts() {
  if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    return const [];
  }
  return SerialPort.availablePorts;
}
