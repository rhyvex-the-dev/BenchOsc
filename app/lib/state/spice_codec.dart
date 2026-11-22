part of 'circuit_doc.dart';

double? _parseSpiceToken(String token) {
  final clean = token.trim().replaceAll(RegExp(r'^[(),]+|[(),]+$'), '');
  if (clean.isEmpty) return null;
  final plain = double.tryParse(clean);
  if (plain != null) return plain;

  final match = RegExp(r'^([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)\s*([a-zA-ZωΩ]+)$')
      .firstMatch(clean);
  if (match == null) return null;
  final base = double.tryParse(match.group(1)!);
  if (base == null) return null;
  final tail = match.group(2)!;
  final tailLower = tail.toLowerCase();

  // Bare unit words/symbols (10F = 10 Farads, while 10f = 10 femto).
  if (tail == 'F' ||
      const {'v', 'a', 'h', 's', 'w', 'hz', 'ohm', 'ohms', 'ω'}.contains(tailLower)) {
    return base;
  }

  String? pfx;
  String unit = tailLower;
  if (tailLower.startsWith('meg')) {
    pfx = 'meg';
    unit = tailLower.substring(3);
  } else {
    pfx = tail[0];
    unit = tailLower.substring(1);
  }
  if (!const {'', 'ohm', 'ohms', 'ω', 'hz', 'v', 'a', 'f', 'h', 's', 'w'}.contains(unit)) {
    return null;
  }
  final mult = switch (pfx) {
    'M' => 1e6,
    'm' => 1e-3,
    'meg' => 1e6,
    _ => switch (pfx.toLowerCase()) {
      'f' => 1e-15,
      'p' => 1e-12,
      'n' => 1e-9,
      'u' => 1e-6,
      'k' => 1e3,
      'g' => 1e9,
      't' => 1e12,
      _ => null,
    },
  };
  return mult == null ? null : base * mult;
}

extension CircuitDocSpice on CircuitDoc {
  // shortcut: Dart mirrors spice_io::export_cir for .SUBCKT blocks and sim==null callers without mutating active SimHandle; replace if Rust exposes stateless .SUBCKT export.
  void _writeSpiceComp(
    StringBuffer buf,
    PlacedComponent c,
    Map<PinRef, int> nodeLookup,
    Map<String, String> models,
  ) {
    if (c.kind == CompKind.ground || c.kind == CompKind.netPort) return;
    int n(int idx) => idx < c.pinOffsets.length ? (nodeLookup[PinRef(c.id, idx)] ?? 0) : 0;
    double p(int idx, [double d = 0.0]) => idx < c.params.length ? c.params[idx] : d;
    if (c.kind == CompKind.subcircuit && c.subcircuitName != null) {
      final args = [for (var i = 0; i < c.pinOffsets.length; i++) n(i)].join(' ');
      buf.writeln('X${c.id} $args ${c.subcircuitName}');
      return;
    }
    switch (c.kind) {
      case CompKind.resistor || CompKind.lamp || CompKind.buzzer:
        buf.writeln('R${c.id} ${n(0)} ${n(1)} ${p(0, 1000.0)}');
      case CompKind.fuse:
        final rFuse = c.fault == FaultType.open ? 1e9 : p(1, 0.05);
        buf.writeln('Rfuse${c.id} ${n(0)} ${n(1)} $rFuse');
      case CompKind.capacitor || CompKind.polarizedCapacitor || CompKind.varCapacitor:
        buf.writeln('C${c.id} ${n(0)} ${n(1)} ${p(0, 1e-6)}');
      case CompKind.inductor || CompKind.varInductor:
        buf.writeln('L${c.id} ${n(0)} ${n(1)} ${p(0, 1e-2)}');
      case CompKind.dcSource:
        buf.writeln('V${c.id} ${n(0)} ${n(1)} DC ${p(0, 5.0)}');
      case CompKind.powerRail:
        buf.writeln('V${c.id} ${n(0)} 0 DC ${p(0, 5.0)}');
      case CompKind.dcCurrent:
        buf.writeln('I${c.id} ${n(0)} ${n(1)} DC ${p(0, 0.01)}');
      case CompKind.acSource:
        buf.writeln('V${c.id} ${n(0)} ${n(1)} SIN(${p(3)} ${p(0, 5.0)} ${p(1, 100.0)} 0 0 ${p(2)})');
      case CompKind.acCurrent:
        buf.writeln('I${c.id} ${n(0)} ${n(1)} SIN(${p(3)} ${p(0, 0.01)} ${p(1, 100.0)} 0 0 ${p(2)})');
      case CompKind.funcGen:
        final shape = p(0).round();
        final amp = p(1, 5.0);
        final freq = p(2, 120.0);
        final off = p(3);
        if (shape == 1) {
          final period = freq > 0 ? 1.0 / freq : 1.0;
          final pw = period * p(4, 0.5).clamp(0.01, 0.99);
          buf.writeln('V${c.id} ${n(0)} ${n(1)} PULSE(${off - amp} ${off + amp} 0 1n 1n $pw $period)');
        } else if (shape == 2) {
          final period = freq > 0 ? 1.0 / freq : 1.0;
          final half = 0.5 * period;
          buf.writeln('V${c.id} ${n(0)} ${n(1)} PULSE(${off - amp} ${off + amp} 0 $half $half 0 $period)');
        } else {
          buf.writeln('V${c.id} ${n(0)} ${n(1)} SIN($off $amp $freq)');
        }
      case CompKind.pulseVoltage:
        buf.writeln(
          'V${c.id} ${n(0)} ${n(1)} PULSE(${p(0)} ${p(1, 5.0)} ${p(2)} ${p(3, 1e-6)} ${p(4, 1e-6)} ${p(5, 5e-4)} ${p(6, 1e-3)})',
        );
      case CompKind.pwlSource:
        buf.writeln(
          'V${c.id} ${n(0)} ${n(1)} PWL(${p(0)} ${p(1)} ${p(2)} ${p(3)} ${p(4)} ${p(5)} ${p(6)} ${p(7)})',
        );
      case CompKind.clock:
        final freq = p(0, 100.0);
        final period = freq > 0 ? 1.0 / freq : 1.0;
        buf.writeln('Vclk${c.id} ${n(0)} ${n(1)} PULSE(0 ${p(1, 5.0)} 0 1n 1n ${0.5 * period} $period)');
      case CompKind.potentiometer:
        final w = p(1, 0.5).clamp(0.001, 0.999);
        final rTot = p(0, 2000.0);
        buf.writeln('R${c.id}a ${n(0)} ${n(2)} ${rTot * (1 - w)}');
        buf.writeln('R${c.id}b ${n(2)} ${n(1)} ${rTot * w}');
      case CompKind.zener:
        final m = 'DZ${c.id}';
        models[m] = '.model $m D(IS=${p(0, 1e-12)} N=${p(1, 1.5)} BV=${p(2, 5.1)})';
        buf.writeln('D${c.id} ${n(0)} ${n(1)} $m');
      case CompKind.varactorDiode:
        final m = 'DVAR${c.id}';
        models[m] = '.model $m D(IS=${p(3, 1e-12)} CJO=${p(0, 20e-12)} VJ=${p(1, 0.7)} M=${p(2, 0.5)})';
        buf.writeln('D${c.id} ${n(0)} ${n(1)} $m');
      case CompKind.diode || CompKind.schottkyDiode || CompKind.led:
        final spec = 'D(IS=${p(0, 1e-12)} N=${p(1, 1.5)})';
        final full = '.model DMOD $spec';
        final existing = models['DMOD'];
        final m = (existing == null || existing == full) ? 'DMOD' : 'DMOD${c.id}';
        models.putIfAbsent(m, () => '.model $m $spec');
        buf.writeln('D${c.id} ${n(0)} ${n(1)} $m');
      case CompKind.opAmp:
        buf.writeln('Eop${c.id} ${n(2)} 0 ${n(0)} ${n(1)} ${p(0, 1e5)}');
      case CompKind.npnBjt:
        final m = 'QNPN${c.id}';
        models[m] = '.model $m NPN(IS=${p(0, 1e-14)} BF=${p(1, 100.0)})';
        buf.writeln('Q${c.id} ${n(0)} ${n(1)} ${n(2)} $m');
      case CompKind.pnpBjt:
        final m = 'QPNP${c.id}';
        models[m] = '.model $m PNP(IS=${p(0, 1e-14)} BF=${p(1, 100.0)})';
        buf.writeln('Q${c.id} ${n(0)} ${n(1)} ${n(2)} $m');
      case CompKind.nmos:
        final m = 'NMOS${c.id}';
        models[m] = '.model $m NMOS(KP=${p(0, 2e-3)} VTO=${p(1, 1.0)} LAMBDA=${p(2, 0.0)})';
        buf.writeln('M${c.id} ${n(0)} ${n(1)} ${n(2)} ${n(2)} $m');
      case CompKind.pmos:
        final m = 'PMOS${c.id}';
        models[m] = '.model $m PMOS(KP=${p(0, 2e-3)} VTO=${p(1, 1.0)} LAMBDA=${p(2, 0.0)})';
        buf.writeln('M${c.id} ${n(0)} ${n(1)} ${n(2)} ${n(2)} $m');
      case CompKind.njfet:
        final m = 'NJF${c.id}';
        models[m] = '.model $m NJF(BETA=${p(0, 1e-3)} VTO=${p(1, -2.0)} LAMBDA=${p(2, 0.01)})';
        buf.writeln('J${c.id} ${n(0)} ${n(1)} ${n(2)} $m');
      case CompKind.pjfet:
        final m = 'PJF${c.id}';
        models[m] = '.model $m PJF(BETA=${p(0, 1e-3)} VTO=${p(1, -2.0)} LAMBDA=${p(2, 0.01)})';
        buf.writeln('J${c.id} ${n(0)} ${n(1)} ${n(2)} $m');
      case CompKind.vControlledSwitch:
        final m = 'SW${c.id}';
        final von = p(0, 3.0), voff = p(1, 1.0);
        models[m] = '.model $m SW(VT=${0.5 * (von + voff)} VH=${0.5 * (von - voff).abs()} RON=${p(2, 1e-3)} ROFF=${p(3, 1e9)})';
        buf.writeln('S${c.id} ${n(0)} ${n(1)} ${n(2)} ${n(3)} $m');
      case CompKind.coupledInductor:
        buf.writeln('L${c.id}a ${n(0)} ${n(1)} ${p(0, 1e-3)}');
        buf.writeln('L${c.id}b ${n(2)} ${n(3)} ${p(1, 1e-3)}');
        buf.writeln('K${c.id} L${c.id}a L${c.id}b ${p(2, 0.9)}');
      case CompKind.vcvs:
        buf.writeln('E${c.id} ${n(0)} ${n(1)} ${n(2)} ${n(3)} ${p(0, 2.0)}');
      case CompKind.vccs:
        buf.writeln('G${c.id} ${n(0)} ${n(1)} ${n(2)} ${n(3)} ${p(0, 0.002)}');
      case CompKind.switchSpst || CompKind.pushbutton:
        final closed = p(0) >= 0.5;
        buf.writeln('Rsw${c.id} ${n(0)} ${n(1)} ${closed ? p(1, 1e-3) : p(2, 1e9)}');
      case CompKind.switchSpdt:
        final tb = p(0) >= 0.5;
        buf.writeln('Rsw${c.id}a ${n(0)} ${n(1)} ${tb ? 1e9 : 1e-3}');
        buf.writeln('Rsw${c.id}b ${n(0)} ${n(2)} ${tb ? 1e-3 : 1e9}');
      default:
        buf.writeln('* ${c.kind.name} U${c.id} ${n(0)} ${n(1)}');
    }
  }

  String toSpiceCir({SimFfi? sim}) {
    if (sim != null && subcircuits.isEmpty) {
      return sim.exportCir();
    }
    resolveNets();
    final models = <String, String>{};
    final buf = StringBuffer('* Open Bench Schematic\n');
    for (final def in subcircuits.values) {
      final portList = [for (var i = 1; i <= def.externalPins.length; i++) i];
      final (subNodes, _, _) = _resolveSubcircuitNodes(def, portList, portList.length + 1);
      buf.writeln('.SUBCKT ${def.name} ${portList.join(' ')}');
      for (final ic in def.components) {
        _writeSpiceComp(buf, ic, subNodes, models);
      }
      buf.writeln('.ENDS ${def.name}');
    }
    for (final c in components) {
      _writeSpiceComp(buf, c, resolvedNodes, models);
    }
    for (final card in models.values) {
      buf.writeln(card);
    }
    buf.writeln('.end');
    return buf.toString();
  }

  /// Imports SPICE `.cir` lines (R, C, L, V/I DC/SIN/PULSE, D, Q, M, J, E/Eop, G, `.model`, `+`, `.SUBCKT`/`X`).
  void loadSpiceCir(String text) {
    final savedRevision = revision;
    final savedComps = components.map((c) => c.copyWith()).toList();
    final savedWires = List<WireLink>.from(wires);
    final savedNotes = List<SchematicNote>.from(notes);
    final savedSubs = Map<String, SubcircuitDef>.from(subcircuits);
    final savedCh1 = probeCh1;
    final savedCh2 = probeCh2;
    final savedCh3 = probeCh3;
    final savedCh4 = probeCh4;
    final savedNextId = _nextId;

    components = [];
    wires = [];
    subcircuits.clear();
    notes = [];
    _nextId = 1;
    final netIds = <String, int>{'0': 0, 'gnd': 0};
    var nextNet = 1;
    int parseNet(String token) {
      final key = token.trim().toLowerCase();
      if (key == '0' || key == 'gnd') return 0;
      return netIds.putIfAbsent(key, () => nextNet++);
    }

    // Join SPICE '+' continuation lines before parsing statements.
    final joinedLines = <String>[];
    for (final raw in text.split('\n')) {
      final t = raw.trim();
      if (t.isEmpty || t.startsWith('*')) continue;
      if (t.startsWith('+') && joinedLines.isNotEmpty) {
        joinedLines[joinedLines.length - 1] = '${joinedLines.last} ${t.substring(1).trim()}';
      } else {
        joinedLines.add(t);
      }
    }

    final models = <String, ({String type, Map<String, double> kv})>{};
    for (final line in joinedLines) {
      final m = RegExp(
        r'^\.MODEL\s+(\S+)\s+([^\s(]+)(?:\s*\(([^)]*)\)|\s+(.*))?',
        caseSensitive: false,
      ).firstMatch(line);
      if (m != null) {
        final kv = <String, double>{};
        final body = m.group(3) ?? m.group(4) ?? '';
        for (final tok in body.split(RegExp(r'[\s,]+'))) {
          final eq = tok.indexOf('=');
          if (eq <= 0) continue;
          final v = _parseSpiceToken(tok.substring(eq + 1));
          if (v != null) kv[tok.substring(0, eq).trim().toUpperCase()] = v;
        }
        models[m.group(1)!.toUpperCase()] = (type: m.group(2)!.toUpperCase(), kv: kv);
      }
    }

    final nodeAnchor = <int, PinRef>{};
    var col = 4;
    var row = 4;
    var parsedCount = 0;

    void linkTopNode(int net, PinRef pin) {
      if (net == 0) {
        final g = addComponent(CompKind.ground, col, row + 3, recordUndo: false);
        wires.add(WireLink(pin, PinRef(g.id, 0)));
        return;
      }
      final prev = nodeAnchor[net];
      if (prev != null) {
        wires.add(WireLink(prev, pin));
      } else {
        nodeAnchor[net] = pin;
      }
    }

    String? subName;
    var subPortIdx = <String, int>{};
    var subPortLabels = <String>[];
    var subComps = <PlacedComponent>[];
    var subWires = <WireLink>[];
    var subNodeAnchor = <String, PinRef>{};
    var subExtPin = <int, PinRef>{};
    var subCol = 4;
    var subRow = 4;

    bool parseCompLine(
      List<String> parts,
      int gx,
      int gy,
      PlacedComponent Function(CompKind kind, int x, int y) spawn,
      void Function(PlacedComponent comp, List<double> overrides) setParams,
      void Function(String token, PinRef pin) bindToken,
    ) {
      final prefix = parts[0][0].toUpperCase();
      final t0 = parts[1];
      final t1 = parts[2];

      PlacedComponent makeComp(CompKind kind, [List<(int idx, double val)> updates = const []]) {
        final c = spawn(kind, gx, gy);
        if (updates.isNotEmpty) {
          final nextParams = List<double>.from(c.params);
          for (final (idx, val) in updates) {
            if (idx < nextParams.length) nextParams[idx] = val;
          }
          setParams(c, nextParams);
        }
        return c;
      }

      if (prefix == 'V' && parts.length >= 4) {
        final rest = parts.sublist(3).join(' ');
        final sinMatch = RegExp(r'SIN\s*\(([^)]+)\)', caseSensitive: false).firstMatch(rest);
        final pulseMatch = RegExp(r'PULSE\s*\(([^)]+)\)', caseSensitive: false).firstMatch(rest);
        if (sinMatch != null) {
          final args = sinMatch
              .group(1)!
              .trim()
              .split(RegExp(r'[\s,]+'))
              .map(_parseSpiceToken)
              .whereType<double>()
              .toList();
          if (args.length < 3) return false;
          final c = makeComp(CompKind.funcGen, [(1, args[1]), (2, args[2]), (3, args[0])]);
          bindToken(t0, PinRef(c.id, 0));
          bindToken(t1, PinRef(c.id, 1));
          return true;
        }
        if (pulseMatch != null) {
          final args = pulseMatch
              .group(1)!
              .trim()
              .split(RegExp(r'[\s,]+'))
              .map(_parseSpiceToken)
              .whereType<double>()
              .toList();
          if (args.length < 2) return false;
          final c = makeComp(CompKind.pulseVoltage, [
            (0, args[0]),
            (1, args[1]),
            if (args.length >= 3) (2, args[2]),
            if (args.length >= 4) (3, args[3]),
            if (args.length >= 5) (4, args[4]),
            if (args.length >= 6) (5, args[5]),
            if (args.length >= 7) (6, args[6]),
          ]);
          bindToken(t0, PinRef(c.id, 0));
          bindToken(t1, PinRef(c.id, 1));
          return true;
        }
        double? dcVal;
        for (var i = 3; i + 1 < parts.length; i++) {
          if (parts[i].toUpperCase() == 'DC') {
            dcVal = _parseSpiceToken(parts[i + 1]);
            break;
          }
        }
        dcVal ??= _parseSpiceToken(parts.last);
        if (dcVal == null) return false;
        final c = makeComp(CompKind.dcSource, [(0, dcVal)]);
        bindToken(t0, PinRef(c.id, 0));
        bindToken(t1, PinRef(c.id, 1));
        return true;
      }
      if (prefix == 'I' && parts.length >= 4) {
        final rest = parts.sublist(3).join(' ');
        final sinMatch = RegExp(r'SIN\s*\(([^)]+)\)', caseSensitive: false).firstMatch(rest);
        if (sinMatch != null) {
          final args = sinMatch
              .group(1)!
              .trim()
              .split(RegExp(r'[\s,]+'))
              .map(_parseSpiceToken)
              .whereType<double>()
              .toList();
          if (args.length < 3) return false;
          final c = makeComp(CompKind.acCurrent, [
            (0, args[1]),
            (1, args[2]),
            if (args.length >= 6) (2, args[5]),
            (3, args[0]),
          ]);
          bindToken(t0, PinRef(c.id, 0));
          bindToken(t1, PinRef(c.id, 1));
          return true;
        }
        final dcVal = _parseSpiceToken(parts.last);
        if (dcVal == null) return false;
        final c = makeComp(CompKind.dcCurrent, [(0, dcVal)]);
        bindToken(t0, PinRef(c.id, 0));
        bindToken(t1, PinRef(c.id, 1));
        return true;
      }
      if (prefix == 'Q' && parts.length >= 4) {
        final mKey = parts.length >= 5 ? parts[4].toUpperCase() : parts.last.toUpperCase();
        final mod = models[mKey];
        final isPnp = mod?.type == 'PNP' || mKey.contains('PNP');
        final updates = <(int, double)>[
          if (mod?.kv['IS'] != null) (0, mod!.kv['IS']!),
          if (mod?.kv['BF'] != null) (1, mod!.kv['BF']!),
        ];
        final c = makeComp(isPnp ? CompKind.pnpBjt : CompKind.npnBjt, updates);
        bindToken(t0, PinRef(c.id, 0));
        bindToken(t1, PinRef(c.id, 1));
        bindToken(parts[3], PinRef(c.id, 2));
        return true;
      }
      if (prefix == 'M' && parts.length >= 4) {
        final mKey = parts.last.toUpperCase();
        final mod = models[mKey];
        final isPmos = mod?.type == 'PMOS' || mKey.contains('PMOS');
        final updates = <(int, double)>[
          if (mod?.kv['KP'] != null) (0, mod!.kv['KP']!),
          if (mod?.kv['VTO'] != null) (1, mod!.kv['VTO']!),
          if (mod?.kv['LAMBDA'] != null) (2, mod!.kv['LAMBDA']!),
        ];
        final c = makeComp(isPmos ? CompKind.pmos : CompKind.nmos, updates);
        bindToken(t0, PinRef(c.id, 0));
        bindToken(t1, PinRef(c.id, 1));
        bindToken(parts[3], PinRef(c.id, 2));
        return true;
      }
      if (prefix == 'J' && parts.length >= 4) {
        final mKey = parts.length >= 5 ? parts[4].toUpperCase() : parts.last.toUpperCase();
        final mod = models[mKey];
        final isPjf = mod?.type == 'PJF' || mKey.contains('PJF');
        final updates = <(int, double)>[
          if (mod?.kv['BETA'] != null) (0, mod!.kv['BETA']!),
          if (mod?.kv['VTO'] != null) (1, mod!.kv['VTO']!),
          if (mod?.kv['LAMBDA'] != null) (2, mod!.kv['LAMBDA']!),
        ];
        final c = makeComp(isPjf ? CompKind.pjfet : CompKind.njfet, updates);
        bindToken(t0, PinRef(c.id, 0));
        bindToken(t1, PinRef(c.id, 1));
        bindToken(parts[3], PinRef(c.id, 2));
        return true;
      }
      if (prefix == 'D') {
        final mKey = parts.length >= 4 ? parts[3].toUpperCase() : '';
        final mod = models[mKey];
        final bv = mod?.kv['BV'];
        if (bv != null && bv > 0) {
          final c = makeComp(CompKind.zener, [
            if (mod?.kv['IS'] != null) (0, mod!.kv['IS']!),
            if (mod?.kv['N'] != null) (1, mod!.kv['N']!),
            (2, bv),
          ]);
          bindToken(t0, PinRef(c.id, 0));
          bindToken(t1, PinRef(c.id, 1));
          return true;
        }
        final c = makeComp(CompKind.diode, [
          if (mod?.kv['IS'] != null) (0, mod!.kv['IS']!),
          if (mod?.kv['N'] != null) (1, mod!.kv['N']!),
        ]);
        bindToken(t0, PinRef(c.id, 0));
        bindToken(t1, PinRef(c.id, 1));
        return true;
      }
      if ((prefix == 'G' || prefix == 'E') && parts.length >= 6) {
        final gain = _parseSpiceToken(parts[5]);
        if (gain == null) return false;
        if (parts[0].toUpperCase().startsWith('EOP') && (t1 == '0' || t1.toLowerCase() == 'gnd')) {
          final c = makeComp(CompKind.opAmp, [(0, gain)]);
          bindToken(parts[3], PinRef(c.id, 0));
          bindToken(parts[4], PinRef(c.id, 1));
          bindToken(t0, PinRef(c.id, 2));
          return true;
        }
        final c = makeComp(prefix == 'G' ? CompKind.vccs : CompKind.vcvs, [(0, gain)]);
        bindToken(t0, PinRef(c.id, 0));
        bindToken(t1, PinRef(c.id, 1));
        bindToken(parts[3], PinRef(c.id, 2));
        bindToken(parts[4], PinRef(c.id, 3));
        return true;
      }
      if (parts.length >= 4) {
        final CompKind? kind = switch (prefix) {
          'R' => CompKind.resistor,
          'C' => CompKind.capacitor,
          'L' => CompKind.inductor,
          _ => null,
        };
        if (kind == null) return false;
        final val = _parseSpiceToken(parts[3]) ?? _parseSpiceToken(parts.last);
        if (val == null) return false;
        final c = makeComp(kind, [(0, val)]);
        bindToken(t0, PinRef(c.id, 0));
        bindToken(t1, PinRef(c.id, 1));
        return true;
      }
      return false;
    }

    // First pass: parse all .SUBCKT ... .ENDS blocks so forward references work.
    final subByUpper = <String, SubcircuitDef>{};
    for (final line in joinedLines) {
      final upper = line.toUpperCase();
      if (upper.startsWith('.SUBCKT')) {
        final hdr = line.split(RegExp(r'\s+'));
        if (hdr.length >= 2) {
          subName = hdr[1];
          subPortLabels = hdr.sublist(2);
          subPortIdx = {
            for (var i = 0; i < subPortLabels.length; i++) subPortLabels[i].toLowerCase(): i,
          };
          subComps = [];
          subWires = [];
          subNodeAnchor = {};
          subExtPin = {};
          subCol = 4;
          subRow = 4;
        }
        continue;
      }
      if (upper.startsWith('.ENDS')) {
        if (subName != null && subComps.isNotEmpty) {
          final extPins = <PinRef>[
            for (var i = 0; i < subPortLabels.length; i++)
              subExtPin.putIfAbsent(i, () {
                final nc = PlacedComponent(
                  id: _nextId++,
                  kind: CompKind.netPort,
                  gridX: subCol,
                  gridY: subRow,
                  params: const [],
                  hexPattern: subPortLabels[i],
                );
                subComps.add(nc);
                return PinRef(nc.id, 0);
              }),
          ];
          final def = SubcircuitDef(
            name: subName,
            components: subComps,
            wires: subWires,
            externalPins: extPins,
            pinLabels: List<String>.from(subPortLabels),
          );
          subcircuits[subName] = def;
          subByUpper[subName.toUpperCase()] = def;
        }
        subName = null;
        continue;
      }
      if (subName == null || line.startsWith('.')) continue;

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 3) continue;

      final added = parseCompLine(
        parts,
        subCol,
        subRow,
        (kind, x, y) {
          final c = PlacedComponent(
            id: _nextId++,
            kind: kind,
            gridX: x,
            gridY: y,
            params: List<double>.from(kCompMeta[kind]!.defaults),
          );
          subComps.add(c);
          return c;
        },
        (comp, overrides) {
          final idx = subComps.indexWhere((e) => e.id == comp.id);
          if (idx >= 0) subComps[idx] = subComps[idx].copyWith(params: overrides);
        },
        (token, pin) {
          final key = token.trim().toLowerCase();
          if (key == '0' || key == 'gnd') {
            final g = PlacedComponent(
              id: _nextId++,
              kind: CompKind.ground,
              gridX: subCol,
              gridY: subRow + 3,
              params: const [],
            );
            subComps.add(g);
            subWires.add(WireLink(pin, PinRef(g.id, 0)));
            return;
          }
          final portI = subPortIdx[key];
          if (portI != null) subExtPin.putIfAbsent(portI, () => pin);
          final prev = subNodeAnchor[key];
          if (prev != null) {
            subWires.add(WireLink(prev, pin));
          } else {
            subNodeAnchor[key] = pin;
          }
        },
      );
      if (added) {
        subCol += 5;
        if (subCol > 20) {
          subCol = 4;
          subRow += 5;
        }
      }
    }

    var inSubckt = false;
    for (final line in joinedLines) {
      final upper = line.toUpperCase();
      if (upper.startsWith('.SUBCKT')) {
        inSubckt = true;
        continue;
      }
      if (upper.startsWith('.ENDS')) {
        inSubckt = false;
        continue;
      }
      if (inSubckt || line.startsWith('.')) continue;

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 3) continue;

      if (parts[0][0].toUpperCase() == 'X' && parts.length >= 3) {
        final def = subByUpper[parts.last.toUpperCase()];
        if (def != null) {
          final c = PlacedComponent(
            id: _nextId++,
            kind: CompKind.subcircuit,
            gridX: col,
            gridY: row,
            params: const [],
            subcircuitName: def.name,
            customPinCount: def.externalPins.length,
          );
          components.add(c);
          for (var k = 0; k < def.externalPins.length && (1 + k) < parts.length - 1; k++) {
            linkTopNode(parseNet(parts[1 + k]), PinRef(c.id, k));
          }
          parsedCount++;
          col += 5;
          if (col > 20) {
            col = 4;
            row += 5;
          }
        }
        continue;
      }

      final ok = parseCompLine(
        parts,
        col,
        row,
        (kind, x, y) => addComponent(kind, x, y, recordUndo: false),
        (comp, overrides) {
          final idx = components.indexWhere((e) => e.id == comp.id);
          if (idx >= 0) components[idx] = components[idx].copyWith(params: overrides);
        },
        (token, pin) => linkTopNode(parseNet(token), pin),
      );
      if (ok) {
        parsedCount++;
        col += 5;
        if (col > 20) {
          col = 4;
          row += 5;
        }
      }
    }

    if (parsedCount == 0) {
      components = savedComps;
      wires = savedWires;
      notes = savedNotes;
      subcircuits
        ..clear()
        ..addAll(savedSubs);
      probeCh1 = savedCh1;
      probeCh2 = savedCh2;
      probeCh3 = savedCh3;
      probeCh4 = savedCh4;
      _nextId = savedNextId;
      revision = savedRevision;
      throw const FormatException('Empty or invalid SPICE netlist');
    }

    final newComps = components;
    final newWires = wires;
    final newNotes = notes;
    final newSubs = Map<String, SubcircuitDef>.from(subcircuits);
    final newNextId = _nextId;
    components = savedComps;
    wires = savedWires;
    notes = savedNotes;
    subcircuits
      ..clear()
      ..addAll(savedSubs);
    probeCh1 = savedCh1;
    probeCh2 = savedCh2;
    probeCh3 = savedCh3;
    probeCh4 = savedCh4;
    _nextId = savedNextId;
    _pushUndo();

    components = newComps;
    wires = newWires;
    notes = newNotes;
    subcircuits
      ..clear()
      ..addAll(newSubs);
    _nextId = newNextId;
    probeCh1 = nodeAnchor[1];
    probeCh2 = nodeAnchor[2] ?? nodeAnchor[1];
    probeCh3 = null;
    probeCh4 = null;
    revision++;
  }
}
