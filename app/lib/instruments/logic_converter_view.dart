import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/circuit_theme.dart';

class LogicConverterView extends StatefulWidget {
  final Future<String> Function(int varCount, List<int> outputs)? onMinimizeAsync;
  final void Function(int varCount, String expr, {bool nandOnly})? onBuildCircuit;
  final Future<(int varCount, List<int> outputs)?> Function()? onExtractFromCircuit;

  const LogicConverterView({
    super.key,
    this.onMinimizeAsync,
    this.onBuildCircuit,
    this.onExtractFromCircuit,
  });

  @override
  State<LogicConverterView> createState() => _LogicConverterViewState();
}

class _LogicConverterViewState extends State<LogicConverterView> {
  int _vars = 2;
  List<int> _outputs = [0, 1, 1, 0]; // 0, 1, 2 (Don't-Care X)
  String _expr = "A'B + AB'";
  String _posExpr = '';
  bool _nandMode = false;
  bool _posMode = false;
  bool _extracting = false;
  int _minEpoch = 0;
  late final TextEditingController _inputCtrl;
  String? _parseError;

  @override
  void initState() {
    super.initState();
    _recomputeExpr(updateInput: false);
    _inputCtrl = TextEditingController(text: _posMode ? _posExpr : _expr);
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  String _sopToPos(String compSop) {
    final t = compSop.trim();
    if (t == '0') return '1';
    if (t == '1') return '0';
    final terms = t.split('+').map((s) => s.trim()).where((s) => s.isNotEmpty);
    final litRe = RegExp(r"([A-Z])('?)");
    final maxterms = <String>[];
    for (final term in terms) {
      final lits = <String>[];
      for (final m in litRe.allMatches(term)) {
        final v = m.group(1)!;
        final neg = m.group(2) == "'";
        lits.add(neg ? v : "$v'");
      }
      if (lits.isNotEmpty) maxterms.add('(${lits.join('+')})');
    }
    return maxterms.isEmpty ? '1' : maxterms.join('');
  }

  String _rawSop(int vars, List<int> outs) {
    final rows = 1 << vars;
    var hasOne = false;
    var allHighOrDc = true;
    final terms = <String>[];
    for (var i = 0; i < rows && i < outs.length; i++) {
      if (outs[i] == 1) {
        hasOne = true;
        if (terms.length < 16) {
          final buf = StringBuffer();
          for (var b = 0; b < vars; b++) {
            final v = String.fromCharCode(65 + b);
            final bit = ((i >> (vars - 1 - b)) & 1) == 1;
            buf.write(bit ? v : "$v'");
          }
          terms.add(buf.toString());
        }
      } else if (outs[i] == 0) {
        allHighOrDc = false;
      }
    }
    if (!hasOne) return '0';
    if (allHighOrDc) return '1';
    return terms.join(' + ');
  }

  void _recomputeExpr({bool updateInput = true}) {
    if (widget.onMinimizeAsync != null) {
      _recomputeExprAsync(updateInput: updateInput);
      return;
    }
    final compOuts = [for (final v in _outputs) v == 0 ? 1 : (v == 1 ? 0 : 2)];
    _expr = _rawSop(_vars, _outputs);
    _posExpr = _sopToPos(_rawSop(_vars, compOuts));
    if (updateInput) _inputCtrl.text = _posMode ? _posExpr : _expr;
  }

  Future<void> _recomputeExprAsync({bool updateInput = true}) async {
    final fn = widget.onMinimizeAsync;
    if (fn == null) return;
    final epoch = ++_minEpoch;
    final vars = _vars;
    final outs = List<int>.from(_outputs);
    final compOuts = [for (final v in outs) v == 0 ? 1 : (v == 1 ? 0 : 2)];
    try {
      final results = await Future.wait([fn(vars, outs), fn(vars, compOuts)]);
      if (!mounted || epoch != _minEpoch) return;
      setState(() {
        _expr = results[0];
        _posExpr = _sopToPos(results[1]);
        if (updateInput) _inputCtrl.text = _posMode ? _posExpr : _expr;
      });
    } catch (_) {
      if (!mounted || epoch != _minEpoch) return;
      setState(() => _parseError = 'Minimization failed');
    }
  }

  void _toggleRow(int idx) {
    setState(() {
      _outputs[idx] = (_outputs[idx] + 1) % 3;
      _recomputeExpr();
      _parseError = null;
    });
  }

  void _applyExpression(String raw) {
    final res = evalBooleanExprList(raw, _vars);
    if (res == null) {
      setState(() => _parseError = 'Use A..H, *, &, +, |, ^, !, ~, ()');
      return;
    }
    setState(() {
      _parseError = null;
      _outputs = res;
      _recomputeExpr(updateInput: false);
    });
  }

  Future<void> _extractCircuit() async {
    if (widget.onExtractFromCircuit == null || _extracting) return;
    setState(() => _extracting = true);
    try {
      final res = await widget.onExtractFromCircuit!();
      if (!mounted) return;
      setState(() {
        _extracting = false;
        if (res != null) {
          _vars = res.$1.clamp(1, 8);
          _outputs = List<int>.from(res.$2);
          _parseError = null;
          _recomputeExpr();
        } else {
          _parseError = 'Need inputs & CH2/Probe output';
        }
      });
    } finally {
      if (mounted && _extracting) setState(() => _extracting = false);
    }
  }

  String _toNandExpr(String sop) {
    final t = sop.trim();
    if (t == '0' || t == '1') return t;
    final terms = t.split('+').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (terms.length == 1) return "NAND(${terms.first})'";
    return 'NAND(${terms.map((p) => "($p)'").join(', ')})';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CircuitColors>()!;
    final l10n = AppLocalizations.of(context)!;
    final rowCount = 1 << _vars;
    final varNames = const ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'].take(_vars).join(' ');

    return Container(
      decoration: BoxDecoration(
        color: colors.panelSurface,
        border: Border.all(color: colors.panelBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(8),
      child: LayoutBuilder(
        builder: (context, box) {
          final header = Wrap(
            spacing: 6,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.memory, size: 16, color: colors.accentAmber),
                  const SizedBox(width: 4),
                  Text(
                    l10n.logicConverterTitle,
                    style: TextStyle(color: colors.componentStroke, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${l10n.variablesLabel}: ', style: TextStyle(color: colors.componentStroke, fontSize: 12)),
                  DropdownButton<int>(
                    value: _vars,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: const [1, 2, 3, 4, 5, 6, 7, 8]
                        .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() {
                        final old = _outputs;
                        _vars = v;
                        final nextRows = 1 << v;
                        _outputs = List<int>.generate(nextRows, (i) => i < old.length ? old[i] : 0);
                        _recomputeExpr();
                        _parseError = null;
                      });
                    },
                  ),
                ],
              ),
              ChoiceChip(
                selected: _nandMode,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                label: Text(_nandMode ? 'NAND' : 'SOP', style: TextStyle(fontSize: 10, color: colors.componentStroke)),
                onSelected: (v) => setState(() => _nandMode = v),
              ),
              ChoiceChip(
                selected: _posMode,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                label: Text('POS', style: TextStyle(fontSize: 10, color: colors.componentStroke)),
                onSelected: (v) => setState(() => _posMode = v),
              ),
              if (widget.onExtractFromCircuit != null)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: _extracting ? null : _extractCircuit,
                  child: const Text('From Ckt', style: TextStyle(fontSize: 11)),
                ),
              if (widget.onBuildCircuit != null)
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: () => widget.onBuildCircuit!(_vars, _expr, nandOnly: _nandMode),
                  child: Text(l10n.buildCircuitButton, style: const TextStyle(fontSize: 11)),
                ),
            ],
          );
          final inputRow = Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inputCtrl,
                  style: TextStyle(color: colors.componentStroke, fontSize: 12, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    hintText: 'A^B + !C',
                    border: const OutlineInputBorder(),
                    errorText: _parseError,
                  ),
                  onSubmitted: _applyExpression,
                ),
              ),
              const SizedBox(width: 6),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: () => _applyExpression(_inputCtrl.text),
                child: const Text('Apply', style: TextStyle(fontSize: 11)),
              ),
            ],
          );
          final colsHeader = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Row(
              children: [
                Text(varNames, style: TextStyle(color: colors.accentAmber, fontFamily: 'monospace', fontSize: 11)),
                const Spacer(),
                Text('Y (0/1/X)', style: TextStyle(color: colors.accentAmber, fontFamily: 'monospace', fontSize: 11)),
              ],
            ),
          );
          final truthTable = ListView.builder(
            itemCount: rowCount,
            itemBuilder: (context, row) {
              final bits = List.generate(
                _vars,
                (i) => ((row >> (_vars - 1 - i)) & 1).toString(),
              ).join(' ');
              final out = row < _outputs.length ? _outputs[row] : 0;
              final lbl = out == 2 ? 'X' : '$out';
              return InkWell(
                onTap: () => _toggleRow(row),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: colors.panelBorder)),
                  ),
                  child: Row(
                    children: [
                      Text(bits, style: TextStyle(color: colors.componentStroke, fontFamily: 'monospace')),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                        decoration: BoxDecoration(
                          color: out == 1
                              ? colors.accentAmber
                              : (out == 2 ? colors.scopeCh2.withAlpha(80) : colors.canvasBackground),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: colors.panelBorder),
                        ),
                        child: Text(
                          lbl,
                          style: TextStyle(
                            color: out == 1 ? Colors.black : colors.componentStroke,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
          final footer = Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: colors.canvasBackground,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: colors.panelBorder),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 64),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_posMode ? "POS" : l10n.booleanExprLabel}: ${_posMode ? _posExpr : _expr}',
                      style: TextStyle(color: colors.accentAmber, fontWeight: FontWeight.w600),
                    ),
                    if (_nandMode)
                      Text(
                        'NAND-only: ${_toNandExpr(_expr)}',
                        style: TextStyle(color: colors.scopeCh2, fontSize: 11, fontFamily: 'monospace'),
                      ),
                  ],
                ),
              ),
            ),
          );
          if (box.maxHeight < 280) {
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  const SizedBox(height: 4),
                  inputRow,
                  const SizedBox(height: 4),
                  colsHeader,
                  SizedBox(height: 110, child: truthTable),
                  const SizedBox(height: 6),
                  footer,
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: 4),
              inputRow,
              const SizedBox(height: 4),
              colsHeader,
              Expanded(child: truthTable),
              const SizedBox(height: 6),
              footer,
            ],
          );
        },
      ),
    );
  }
}

/// Evaluates a Boolean expression (`A..H`, `*`/`&`/juxtaposition AND, `^` XOR, `+`/`|` OR, `!`/`~` prefix NOT, `'` postfix NOT) across `2^vars` rows.
List<int>? evalBooleanExprList(String src, int vars) {
  final tokens = <String>[];
  var i = 0;
  while (i < src.length) {
    final c = src[i].toUpperCase();
    if (c == ' ' || c == '\t') {
      i++;
      continue;
    }
    if ('+*&|^!~()\''.contains(c) || c == '0' || c == '1' || (c.codeUnitAt(0) >= 65 && c.codeUnitAt(0) < 65 + vars)) {
      tokens.add(c);
      i++;
    } else {
      return null;
    }
  }
  if (tokens.isEmpty) return null;

  var pos = 0;
  var activeRow = 0;
  late final int? Function() parseOr;
  late final int? Function() parseXor;
  late final int? Function() parseAnd;
  late final int? Function() parseUnary;
  late final int? Function() parseAtom;

  parseAtom = () {
    if (pos >= tokens.length) return null;
    final t = tokens[pos++];
    if (t == '0') return 0;
    if (t == '1') return 1;
    if (t == '(') {
      final v = parseOr();
      if (v == null || pos >= tokens.length || tokens[pos++] != ')') return null;
      return v;
    }
    final idx = t.codeUnitAt(0) - 65;
    if (idx >= 0 && idx < vars) {
      return (activeRow >> (vars - 1 - idx)) & 1;
    }
    return null;
  };
  parseUnary = () {
    if (pos < tokens.length && (tokens[pos] == '!' || tokens[pos] == '~')) {
      pos++;
      final v = parseUnary();
      return v == null ? null : (v ^ 1);
    }
    var v = parseAtom();
    while (v != null && pos < tokens.length && tokens[pos] == '\'') {
      pos++;
      v ^= 1;
    }
    return v;
  };
  parseAnd = () {
    final first = parseUnary();
    if (first == null) return null;
    var left = first;
    while (pos < tokens.length) {
      final nxt = tokens[pos];
      if (nxt == '*' || nxt == '&') {
        pos++;
        final r = parseUnary();
        if (r == null) return null;
        left = left & r;
      } else if (nxt == '(' ||
          nxt == '!' ||
          nxt == '~' ||
          (nxt.codeUnitAt(0) >= 65 && nxt.codeUnitAt(0) < 65 + vars)) {
        final r = parseUnary();
        if (r == null) return null;
        left = left & r;
      } else {
        break;
      }
    }
    return left;
  };
  parseXor = () {
    final first = parseAnd();
    if (first == null) return null;
    var left = first;
    while (pos < tokens.length && tokens[pos] == '^') {
      pos++;
      final r = parseAnd();
      if (r == null) return null;
      left = left ^ r;
    }
    return left;
  };
  parseOr = () {
    final first = parseXor();
    if (first == null) return null;
    var left = first;
    while (pos < tokens.length && (tokens[pos] == '+' || tokens[pos] == '|')) {
      pos++;
      final r = parseXor();
      if (r == null) return null;
      left = left | r;
    }
    return left;
  };

  final rows = 1 << vars;
  final outs = List<int>.filled(rows, 0);
  for (var r = 0; r < rows; r++) {
    activeRow = r;
    pos = 0;
    final out = parseOr();
    if (out == null || pos != tokens.length) return null;
    outs[r] = out;
  }
  return outs;
}
