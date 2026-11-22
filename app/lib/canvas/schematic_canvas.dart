import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/circuit_doc.dart';
import '../theme/circuit_theme.dart';
import 'comp_symbols.dart';
import 'wire_router.dart';

export 'comp_symbols.dart' show pinLabel, pinLabelFor;
export 'wire_router.dart' show kGridStep, routeWirePoints;

enum CanvasTool { select, boxSelect, wire, place, probeCh1, probeCh2, probeCh3, probeCh4, delete }

class SchematicCanvas extends StatefulWidget {
  final CircuitDoc doc;
  final CanvasTool tool;
  final CompKind? placingKind;
  final int? selectedCompId;
  final Set<int> selectedCompIds;
  final PinRef? pendingWirePin;
  final Map<int, double> nodeVoltages;
  final Map<int, double> compCurrents;
  final double animPhase;
  final bool showLabels;
  final bool showNodeVoltages;
  final bool showFlow;
  final Set<int> overloadedIds;
  final Set<int> blownFuseIds;
  final int errCode;
  final int errDetail;
  final ValueChanged<int?> onSelectComponent;
  final ValueChanged<Offset> onPlaceAtGrid;
  final ValueChanged<PinRef> onTapPin;
  final void Function(int compId, int gx, int gy, bool finish) onMoveComponent;
  final ValueChanged<int> onToggleSwitch;
  final ValueChanged<int> onDeleteComponent;
  final ValueChanged<int> onDeleteWire;
  final ValueChanged<Set<int>>? onBoxSelect;
  final void Function(int compId, bool closed)? onMomentaryButton;
  final void Function(int wireIdx, int bendX, bool finish)? onMoveWireBend;
  final VoidCallback? onDragStart;
  final void Function(int wireIdx, int gx, int gy)? onSplitWireJunction;
  final void Function(CompKind kind, int gx, int gy)? onDropCompFromPalette;
  final void Function(int? compId, int? wireIdx, int? noteId, Offset globalPos, int gx, int gy)?
      onContextMenu;
  final void Function(int noteId, int gx, int gy, bool finish)? onMoveNote;
  final ValueChanged<int>? onEditNote;
  final int fitTrigger;
  final int zoomInTrigger;
  final int zoomOutTrigger;
  final int zoomResetTrigger;
  final ValueChanged<double>? onZoomChanged;
  final bool coarseGridSnap;
  final bool showPinTooltips;

  const SchematicCanvas({
    super.key,
    required this.doc,
    required this.tool,
    required this.placingKind,
    required this.selectedCompId,
    this.selectedCompIds = const {},
    required this.pendingWirePin,
    required this.nodeVoltages,
    required this.compCurrents,
    required this.animPhase,
    this.showLabels = true,
    this.showNodeVoltages = false,
    this.showFlow = true,
    this.overloadedIds = const {},
    this.blownFuseIds = const {},
    this.errCode = 0,
    this.errDetail = 0,
    required this.onSelectComponent,
    required this.onPlaceAtGrid,
    required this.onTapPin,
    required this.onMoveComponent,
    required this.onToggleSwitch,
    required this.onDeleteComponent,
    required this.onDeleteWire,
    this.onBoxSelect,
    this.onMomentaryButton,
    this.onMoveWireBend,
    this.onDragStart,
    this.onSplitWireJunction,
    this.onDropCompFromPalette,
    this.onContextMenu,
    this.onMoveNote,
    this.onEditNote,
    this.fitTrigger = 0,
    this.zoomInTrigger = 0,
    this.zoomOutTrigger = 0,
    this.zoomResetTrigger = 0,
    this.onZoomChanged,
    this.coarseGridSnap = false,
    this.showPinTooltips = true,
  });

  @override
  State<SchematicCanvas> createState() => _SchematicCanvasState();
}

class _SchematicCanvasState extends State<SchematicCanvas> {
  Offset _pan = const Offset(20, 20);
  double _scale = 1.0;

  double _startScale = 1.0;
  Offset _startPan = Offset.zero;
  Offset _startFocal = Offset.zero;
  int? _draggingCompId;
  int? _draggingWireIdx;
  int? _draggingNoteId;
  Offset _dragStartWorld = Offset.zero;
  int _dragStartGx = 0;
  int _dragStartGy = 0;
  int _lastDragDx = 0;
  int _lastDragDy = 0;
  bool _dragUndoRecorded = false;
  Offset? _boxStartWorld;
  Offset? _boxEndWorld;
  Offset? _hoverWorld;
  PinRef? _hoverPin;
  int? _pressedButtonId;
  Size _lastViewSize = Size.zero;
  CircuitDoc? _cachedWireDoc;
  int _cachedWireRevision = -1;
  Set<int>? _cachedObstacles;
  final Map<(PinRef, PinRef, int?, Offset, Offset), List<Offset>> _wireRouteCache = {};

  List<Offset> _cachedWirePoints(WireLink w, Offset a, Offset b) {
    if (!identical(_cachedWireDoc, widget.doc) || _cachedWireRevision != widget.doc.revision) {
      _wireRouteCache.clear();
      _cachedWireDoc = widget.doc;
      _cachedWireRevision = widget.doc.revision;
      _cachedObstacles = buildObstacleGrid(widget.doc);
    }
    return _wireRouteCache.putIfAbsent(
      (w.from, w.to, w.bendX, a, b),
      () => routeWirePoints(widget.doc, w, a, b, obstacles: _cachedObstacles),
    );
  }

  int _snapGrid(double worldCoord) {
    final step = widget.coarseGridSnap ? 2 : 1;
    return (worldCoord / (kGridStep * step)).round() * step;
  }

  void _notifyZoomPostFrame() {
    final cb = widget.onZoomChanged;
    if (cb == null) return;
    final val = _scale;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) cb(val);
    });
  }

  void _applyZoomFactor(double nextScale) {
    final clamped = nextScale.clamp(0.45, 2.8);
    if (!_lastViewSize.isEmpty) {
      final focal = Offset(_lastViewSize.width * 0.5, _lastViewSize.height * 0.5);
      _pan = focal - ((focal - _pan) / _scale) * clamped;
    }
    _scale = clamped;
    _notifyZoomPostFrame();
  }

  @override
  void didUpdateWidget(covariant SchematicCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fitTrigger != oldWidget.fitTrigger) {
      _fitToComponents();
      _notifyZoomPostFrame();
    }
    if (widget.zoomInTrigger != oldWidget.zoomInTrigger) {
      _applyZoomFactor(_scale * 1.2);
    }
    if (widget.zoomOutTrigger != oldWidget.zoomOutTrigger) {
      _applyZoomFactor(_scale / 1.2);
    }
    if (widget.zoomResetTrigger != oldWidget.zoomResetTrigger) {
      _applyZoomFactor(1.0);
    }
  }

  void _fitToComponents() {
    final viewSize = _lastViewSize;
    if (widget.doc.components.isEmpty || viewSize.isEmpty) {
      _pan = const Offset(20, 20);
      _scale = 1.0;
      return;
    }
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final c in widget.doc.components) {
      final wx = c.gridX * kGridStep;
      final wy = c.gridY * kGridStep;
      if (wx - kGridStep * 3 < minX) minX = wx - kGridStep * 3;
      if (wy - kGridStep * 3 < minY) minY = wy - kGridStep * 3;
      if (wx + kGridStep * 3 > maxX) maxX = wx + kGridStep * 3;
      if (wy + kGridStep * 3 > maxY) maxY = wy + kGridStep * 3;
    }
    final w = math.max(kGridStep * 4, maxX - minX);
    final h = math.max(kGridStep * 4, maxY - minY);
    final nextScale = (math.min(viewSize.width / w, viewSize.height / h) * 0.88).clamp(0.45, 2.2);
    final cx = (minX + maxX) * 0.5;
    final cy = (minY + maxY) * 0.5;
    _scale = nextScale;
    _pan = Offset(viewSize.width * 0.5 - cx * nextScale, viewSize.height * 0.5 - cy * nextScale);
  }

  Offset _screenToWorld(Offset p) => (p - _pan) / _scale;

  PlacedComponent? _hitComponent(Offset world) {
    final gx = world.dx / kGridStep;
    final gy = world.dy / kGridStep;
    for (final c in widget.doc.components.reversed) {
      if (c.kind == CompKind.netPort && (c.hexPattern ?? '').startsWith('J')) {
        if ((Offset(gx, gy) - c.pinGridPos(0)).distance <= 1.1) {
          return c;
        }
        continue;
      }
      if ((gx - c.gridX).abs() <= 1.8 && (gy - c.gridY).abs() <= 1.8) {
        return c;
      }
    }
    return null;
  }

  PinRef? _hitPin(Offset world, {double radiusGrid = 0.95}) {
    final gx = world.dx / kGridStep;
    final gy = world.dy / kGridStep;
    PinRef? best;
    var bestDist = radiusGrid;
    for (final c in widget.doc.components) {
      for (var p = 0; p < c.pinOffsets.length; p++) {
        final pos = c.pinGridPos(p);
        final d = (Offset(gx, gy) - pos).distance;
        if (d < bestDist) {
          bestDist = d;
          best = PinRef(c.id, p);
        }
      }
    }
    return best;
  }

  double _distToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lenSq < 1e-6) return (p - a).distance;
    final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lenSq).clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  int? _hitWire(Offset world) {
    final compById = {for (final c in widget.doc.components) c.id: c};
    Offset? pinWorld(PinRef ref) {
      final c = compById[ref.compId];
      if (c != null && ref.pinIdx < c.pinOffsets.length) {
        return c.pinGridPos(ref.pinIdx) * kGridStep;
      }
      return null;
    }

    for (var i = 0; i < widget.doc.wires.length; i++) {
      final w = widget.doc.wires[i];
      final a = pinWorld(w.from);
      final b = pinWorld(w.to);
      if (a == null || b == null) continue;
      final pts = _cachedWirePoints(w, a, b);
      for (var k = 0; k < pts.length - 1; k++) {
        if (_distToSegment(world, pts[k], pts[k + 1]) <= 10.0) {
          return i;
        }
      }
    }
    return null;
  }

  SchematicNote? _hitNote(Offset world) {
    for (final n in widget.doc.notes.reversed) {
      final center = Offset(n.gridX * kGridStep, n.gridY * kGridStep);
      final halfW = math.max(40.0, n.text.length * 3.4 + 10);
      if ((world.dx - center.dx).abs() <= halfW && (world.dy - center.dy).abs() <= 14.0) {
        return n;
      }
    }
    return null;
  }

  void _handleTap(Offset localPos) {
    final world = _screenToWorld(localPos);

    if (widget.tool == CanvasTool.place && widget.placingKind != null) {
      final gx = _snapGrid(world.dx);
      final gy = _snapGrid(world.dy);
      widget.onPlaceAtGrid(Offset(gx.toDouble(), gy.toDouble()));
      return;
    }

    if (widget.tool == CanvasTool.wire ||
        widget.tool == CanvasTool.probeCh1 ||
        widget.tool == CanvasTool.probeCh2 ||
        widget.tool == CanvasTool.probeCh3 ||
        widget.tool == CanvasTool.probeCh4) {
      final pin = _hitPin(world, radiusGrid: 1.25);
      if (pin != null) {
        widget.onTapPin(pin);
        return;
      }
      if (widget.tool == CanvasTool.wire && widget.onSplitWireJunction != null) {
        final wireIdx = _hitWire(world);
        if (wireIdx != null) {
          widget.onSplitWireJunction!(
            wireIdx,
            (world.dx / kGridStep).round(),
            (world.dy / kGridStep).round(),
          );
        }
      }
      return;
    }

    if (widget.tool == CanvasTool.select) {
      final pin = _hitPin(world, radiusGrid: 0.85);
      if (pin != null) {
        widget.onTapPin(pin);
        return;
      }
    }

    final hit = _hitComponent(world);
    if (widget.tool == CanvasTool.delete) {
      if (hit != null) {
        widget.onDeleteComponent(hit.id);
      } else {
        final wireIdx = _hitWire(world);
        if (wireIdx != null) widget.onDeleteWire(wireIdx);
      }
      return;
    }

    if (hit != null) {
      if ((hit.kind == CompKind.switchSpst || hit.kind == CompKind.switchSpdt) &&
          widget.selectedCompId == hit.id) {
        widget.onToggleSwitch(hit.id);
      } else {
        widget.onSelectComponent(hit.id);
      }
    } else {
      final noteHit = _hitNote(world);
      if (noteHit != null && widget.tool == CanvasTool.select && widget.onEditNote != null) {
        widget.onEditNote!(noteHit.id);
      } else {
        widget.onSelectComponent(null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CircuitColors>()!;
    return Semantics(
      label: 'Schematic canvas',
      child: DragTarget<CompKind>(
      onAcceptWithDetails: (details) {
        if (widget.onDropCompFromPalette == null) return;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(details.offset);
        final world = _screenToWorld(local);
        widget.onDropCompFromPalette!(details.data, _snapGrid(world.dx), _snapGrid(world.dy));
      },
      builder: (context, _, _) => MouseRegion(
      onHover: (e) {
        final world = _screenToWorld(e.localPosition);
        final nextHoverPin = widget.showPinTooltips ? _hitPin(world, radiusGrid: 0.9) : null;
        final trackWire = widget.tool == CanvasTool.wire && widget.pendingWirePin != null;
        if (nextHoverPin != _hoverPin || trackWire) {
          setState(() {
            _hoverPin = nextHoverPin;
            _hoverWorld = trackWire ? world : null;
          });
        }
      },
      onExit: (_) {
        if (_hoverWorld != null || _hoverPin != null) {
          setState(() {
            _hoverWorld = null;
            _hoverPin = null;
          });
        }
      },
      child: Listener(
      onPointerDown: (event) {
        if (widget.tool == CanvasTool.select && widget.onMomentaryButton != null) {
          final world = _screenToWorld(event.localPosition);
          if (_hitPin(world, radiusGrid: 0.85) == null) {
            final hit = _hitComponent(world);
            if (hit != null && hit.kind == CompKind.pushbutton) {
              _pressedButtonId = hit.id;
              widget.onMomentaryButton!(hit.id, true);
            }
          }
        }
      },
      onPointerUp: (_) {
        if (_pressedButtonId != null) {
          widget.onMomentaryButton?.call(_pressedButtonId!, false);
          _pressedButtonId = null;
        }
      },
      onPointerCancel: (_) {
        if (_pressedButtonId != null) {
          widget.onMomentaryButton?.call(_pressedButtonId!, false);
          _pressedButtonId = null;
        }
      },
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          final factor = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
          final nextScale = (_scale * factor).clamp(0.45, 2.8);
          final focal = event.localPosition;
          setState(() {
            _pan = focal - ((focal - _pan) / _scale) * nextScale;
            _scale = nextScale;
          });
          widget.onZoomChanged?.call(_scale);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _handleTap(d.localPosition),
        onSecondaryTapDown: (d) {
          if (widget.onContextMenu == null) return;
          final world = _screenToWorld(d.localPosition);
          final hitComp = _hitComponent(world);
          final hitWire = hitComp == null ? _hitWire(world) : null;
          final hitNote = (hitComp == null && hitWire == null) ? _hitNote(world) : null;
          widget.onContextMenu!(
            hitComp?.id,
            hitWire,
            hitNote?.id,
            d.globalPosition,
            _snapGrid(world.dx),
            _snapGrid(world.dy),
          );
        },
        onScaleStart: (d) {
          _startScale = _scale;
          _startPan = _pan;
          _startFocal = d.localFocalPoint;
          _draggingCompId = null;
          _draggingWireIdx = null;
          _draggingNoteId = null;
          _lastDragDx = 0;
          _lastDragDy = 0;
          _dragUndoRecorded = false;
          if (d.pointerCount == 1 && widget.tool == CanvasTool.boxSelect) {
            final world = _screenToWorld(d.localFocalPoint);
            setState(() {
              _boxStartWorld = world;
              _boxEndWorld = world;
            });
            return;
          }
          if (d.pointerCount == 1 && widget.tool == CanvasTool.select) {
            final world = _screenToWorld(d.localFocalPoint);
            if (_hitPin(world, radiusGrid: 0.85) == null) {
              final hit = _hitComponent(world);
              if (hit != null) {
                final holdPushbutton = hit.kind == CompKind.pushbutton &&
                    widget.onMomentaryButton != null &&
                    !widget.selectedCompIds.contains(hit.id) &&
                    !HardwareKeyboard.instance.isShiftPressed;
                if (!holdPushbutton) {
                  _draggingCompId = hit.id;
                  _dragStartWorld = world;
                  _dragStartGx = hit.gridX;
                  _dragStartGy = hit.gridY;
                }
                if (!widget.selectedCompIds.contains(hit.id)) {
                  widget.onSelectComponent(hit.id);
                }
              } else {
                final wireIdx = _hitWire(world);
                if (wireIdx != null) {
                  _draggingWireIdx = wireIdx;
                } else {
                  final note = _hitNote(world);
                  if (note != null && widget.onMoveNote != null) {
                    _draggingNoteId = note.id;
                    _dragStartWorld = world;
                    _dragStartGx = note.gridX;
                    _dragStartGy = note.gridY;
                  }
                }
              }
            }
          }
        },
        onScaleUpdate: (d) {
          if (_boxStartWorld != null && d.pointerCount == 1) {
            setState(() => _boxEndWorld = _screenToWorld(d.localFocalPoint));
            return;
          }
          if (_draggingWireIdx != null && d.pointerCount == 1) {
            final idx = _draggingWireIdx!;
            final bx = (_screenToWorld(d.localFocalPoint).dx / kGridStep).round();
            if (idx >= 0 && idx < widget.doc.wires.length && bx != widget.doc.wires[idx].bendX) {
              if (!_dragUndoRecorded) {
                _dragUndoRecorded = true;
                widget.onDragStart?.call();
              }
              widget.onMoveWireBend?.call(idx, bx, false);
            }
            return;
          }
          if (_draggingNoteId != null && d.pointerCount == 1) {
            final world = _screenToWorld(d.localFocalPoint);
            final step = widget.coarseGridSnap ? 2 : 1;
            final dxGrid = ((world.dx - _dragStartWorld.dx) / (kGridStep * step)).round() * step;
            final dyGrid = ((world.dy - _dragStartWorld.dy) / (kGridStep * step)).round() * step;
            if (dxGrid != _lastDragDx || dyGrid != _lastDragDy) {
              _lastDragDx = dxGrid;
              _lastDragDy = dyGrid;
              if (!_dragUndoRecorded) {
                _dragUndoRecorded = true;
                widget.onDragStart?.call();
              }
              widget.onMoveNote?.call(
                _draggingNoteId!,
                _dragStartGx + dxGrid,
                _dragStartGy + dyGrid,
                false,
              );
            }
            return;
          }
          if (_draggingCompId != null && d.pointerCount == 1) {
            final world = _screenToWorld(d.localFocalPoint);
            final step = widget.coarseGridSnap ? 2 : 1;
            final dxGrid = ((world.dx - _dragStartWorld.dx) / (kGridStep * step)).round() * step;
            final dyGrid = ((world.dy - _dragStartWorld.dy) / (kGridStep * step)).round() * step;
            if (dxGrid != _lastDragDx || dyGrid != _lastDragDy) {
              _lastDragDx = dxGrid;
              _lastDragDy = dyGrid;
              if (!_dragUndoRecorded) {
                _dragUndoRecorded = true;
                widget.onDragStart?.call();
              }
              widget.onMoveComponent(
                _draggingCompId!,
                _dragStartGx + dxGrid,
                _dragStartGy + dyGrid,
                false,
              );
            }
            return;
          }
          setState(() {
            final nextScale = (_startScale * d.scale).clamp(0.45, 2.8);
            final worldUnderStart = (_startFocal - _startPan) / _startScale;
            _scale = nextScale;
            _pan = d.localFocalPoint - worldUnderStart * nextScale;
          });
          widget.onZoomChanged?.call(_scale);
        },
        onScaleEnd: (_) {
          if (_boxStartWorld != null && _boxEndWorld != null) {
            final rect = Rect.fromPoints(_boxStartWorld!, _boxEndWorld!);
            final hits = <int>{};
            for (final c in widget.doc.components) {
              final pt = Offset(c.gridX * kGridStep, c.gridY * kGridStep);
              if (rect.contains(pt)) hits.add(c.id);
            }
            setState(() {
              _boxStartWorld = null;
              _boxEndWorld = null;
            });
            widget.onBoxSelect?.call(hits);
            return;
          }
          if (_draggingWireIdx != null) {
            final idx = _draggingWireIdx!;
            _draggingWireIdx = null;
            if (_dragUndoRecorded && idx >= 0 && idx < widget.doc.wires.length) {
              final bx = widget.doc.wires[idx].bendX;
              if (bx != null) {
                widget.onMoveWireBend?.call(idx, bx, true);
              }
            }
            return;
          }
          if (_draggingNoteId != null) {
            final note = widget.doc.notes.where((n) => n.id == _draggingNoteId).firstOrNull;
            if (_dragUndoRecorded && note != null) {
              widget.onMoveNote?.call(note.id, note.gridX, note.gridY, true);
            }
            _draggingNoteId = null;
            return;
          }
          if (_draggingCompId != null) {
            final comp = widget.doc.components.where((c) => c.id == _draggingCompId).firstOrNull;
            if (_dragUndoRecorded && comp != null) {
              widget.onMoveComponent(comp.id, comp.gridX, comp.gridY, true);
            }
            _draggingCompId = null;
          }
        },
        child: ClipRect(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _lastViewSize = constraints.biggest;
              return CustomPaint(
                painter: _SchematicPainter(
                  doc: widget.doc,
                  docRevision: widget.doc.revision,
                  colors: colors,
                  pan: _pan,
                  scale: _scale,
                  selectedCompId: widget.selectedCompId,
                  selectedCompIds: widget.selectedCompIds,
                  pendingWirePin: widget.pendingWirePin,
                  showPinHalos: widget.tool == CanvasTool.wire ||
                      widget.tool == CanvasTool.probeCh1 ||
                      widget.tool == CanvasTool.probeCh2 ||
                      widget.tool == CanvasTool.probeCh3 ||
                      widget.tool == CanvasTool.probeCh4,
                  nodeVoltages: widget.nodeVoltages,
                  compCurrents: widget.compCurrents,
                  animPhase: widget.animPhase,
                  showLabels: widget.showLabels,
                  showNodeVoltages: widget.showNodeVoltages,
                  showFlow: widget.showFlow,
                  overloadedIds: widget.overloadedIds,
                  blownFuseIds: widget.blownFuseIds,
                  errCode: widget.errCode,
                  errDetail: widget.errDetail,
                  notesCount: widget.doc.notes.length,
                  probeCh1: widget.doc.probeCh1,
                  probeCh2: widget.doc.probeCh2,
                  probeCh3: widget.doc.probeCh3,
                  probeCh4: widget.doc.probeCh4,
                  routeWire: _cachedWirePoints,
                  pendingWireCursor:
                      widget.tool == CanvasTool.wire && widget.pendingWirePin != null
                          ? _hoverWorld
                          : null,
                  hoverPin: _hoverPin,
                  selectionBox: _boxStartWorld != null && _boxEndWorld != null
                      ? Rect.fromPoints(_boxStartWorld!, _boxEndWorld!)
                      : null,
                ),
                size: Size.infinite,
              );
            },
          ),
        ),
      ),
    ),
    ),
    ),
    );
  }
}

class _SchematicPainter extends CustomPainter {
  final CircuitDoc doc;
  final int docRevision;
  final CircuitColors colors;
  final Offset pan;
  final double scale;
  final int? selectedCompId;
  final Set<int> selectedCompIds;
  final PinRef? pendingWirePin;
  final bool showPinHalos;
  final Map<int, double> nodeVoltages;
  final Map<int, double> compCurrents;
  final double animPhase;
  final bool showLabels;
  final bool showNodeVoltages;
  final bool showFlow;
  final Set<int> overloadedIds;
  final Set<int> blownFuseIds;
  final int errCode;
  final int errDetail;
  final int notesCount;
  final PinRef? probeCh1;
  final PinRef? probeCh2;
  final PinRef? probeCh3;
  final PinRef? probeCh4;
  final List<Offset> Function(WireLink, Offset, Offset) routeWire;
  final Offset? pendingWireCursor;
  final PinRef? hoverPin;
  final Rect? selectionBox;

  _SchematicPainter({
    required this.doc,
    required this.docRevision,
    required this.colors,
    required this.pan,
    required this.scale,
    required this.selectedCompId,
    required this.selectedCompIds,
    required this.pendingWirePin,
    required this.showPinHalos,
    required this.nodeVoltages,
    required this.compCurrents,
    required this.animPhase,
    required this.showLabels,
    required this.showNodeVoltages,
    required this.showFlow,
    required this.overloadedIds,
    this.blownFuseIds = const {},
    this.errCode = 0,
    this.errDetail = 0,
    required this.notesCount,
    required this.probeCh1,
    required this.probeCh2,
    required this.probeCh3,
    required this.probeCh4,
    required this.routeWire,
    this.pendingWireCursor,
    this.hoverPin,
    this.selectionBox,
  });

  Map<int, PlacedComponent> _compById = const {};

  @override
  void paint(Canvas canvas, Size size) {
    _compById = {for (final c in doc.components) c.id: c};
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.canvasBackground);
    canvas.save();
    canvas.translate(pan.dx, pan.dy);
    canvas.scale(scale);

    final topLeft = -pan / scale;
    final botRight = (Offset(size.width, size.height) - pan) / scale;
    _drawGrid(canvas, topLeft, botRight);
    _drawWires(canvas);
    if (pendingWirePin != null && pendingWireCursor != null) {
      final a = _pinWorld(pendingWirePin!);
      if (a != null) {
        final target = Offset(
          (pendingWireCursor!.dx / kGridStep).round() * kGridStep,
          (pendingWireCursor!.dy / kGridStep).round() * kGridStep,
        );
        final midX = ((a.dx + target.dx) * 0.5 / kGridStep).round() * kGridStep;
        final preview = Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(midX, a.dy)
          ..lineTo(midX, target.dy)
          ..lineTo(target.dx, target.dy);
        canvas.drawPath(
          preview,
          Paint()
            ..color = colors.scopeCh2.withAlpha(185)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8,
        );
      }
    }
    _drawComponents(canvas);
    _drawProbes(canvas);
    for (final note in doc.notes) {
      _drawBadge(
        canvas,
        Offset(note.gridX * kGridStep, note.gridY * kGridStep),
        '// ${note.text}',
        colors.panelSurface.withAlpha(235),
        textColor: colors.scopeCh2,
      );
    }
    if (showNodeVoltages) {
      _drawNodeVoltages(canvas);
    }
    if (hoverPin != null) {
      final hp = _pinWorld(hoverPin!);
      final comp = _compById[hoverPin!.compId];
      if (hp != null && comp != null) {
        _drawBadge(
          canvas,
          hp + const Offset(0, -18),
          '${comp.kind.name[0].toUpperCase()}${comp.id} · ${pinLabelFor(comp, hoverPin!.pinIdx, doc)}',
          colors.accentAmber,
        );
      }
    }
    if (selectionBox != null) {
      canvas.drawRect(selectionBox!, Paint()..color = colors.accentAmber.withAlpha(35));
      canvas.drawRect(
        selectionBox!,
        Paint()
          ..color = colors.accentAmber
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4 / scale,
      );
    }

    canvas.restore();
  }

  void _drawGrid(Canvas canvas, Offset tl, Offset br) {
    final minor = Paint()
      ..color = colors.gridMinor
      ..strokeWidth = 0.8 / scale;
    final major = Paint()
      ..color = colors.gridMajor
      ..strokeWidth = 1.1 / scale;

    final startX = (tl.dx / kGridStep).floor();
    final endX = (br.dx / kGridStep).ceil();
    final startY = (tl.dy / kGridStep).floor();
    final endY = (br.dy / kGridStep).ceil();

    for (var gx = startX; gx <= endX; gx++) {
      final x = gx * kGridStep;
      canvas.drawLine(Offset(x, tl.dy), Offset(x, br.dy), gx % 5 == 0 ? major : minor);
    }
    for (var gy = startY; gy <= endY; gy++) {
      final y = gy * kGridStep;
      canvas.drawLine(Offset(tl.dx, y), Offset(br.dx, y), gy % 5 == 0 ? major : minor);
    }
  }

  Offset? _pinWorld(PinRef ref) {
    final c = _compById[ref.compId];
    if (c != null && ref.pinIdx < c.pinOffsets.length) {
      return c.pinGridPos(ref.pinIdx) * kGridStep;
    }
    return null;
  }

  double _pinOutCurrent(PinRef ref) {
    final comp = _compById[ref.compId];
    if (comp == null || comp.kind == CompKind.ground) return 0.0;
    final i = compCurrents[comp.id] ?? 0.0;
    if (comp.kind == CompKind.powerRail) return -i;
    if (comp.kind == CompKind.clock ||
        comp.kind == CompKind.opAmp ||
        comp.kind == CompKind.timer555 ||
        comp.kind == CompKind.schmittTrigger) {
      return ref.pinIdx == comp.pinOffsets.length - 1 ? i : 0.0;
    }
    if (comp.pinOffsets.length == 2) {
      return ref.pinIdx == 0 ? -i : i;
    }
    return ref.pinIdx == 0 ? -i : (ref.pinIdx == 1 ? i : 0.0);
  }

  void _drawWires(Canvas canvas) {
    final pinCounts = <String, int>{};
    final netCurrentMag = <int, double>{};
    for (final c in doc.components) {
      final mag = (compCurrents[c.id] ?? 0.0).abs();
      if (mag <= 2e-5) continue;
      for (var p = 0; p < c.pinOffsets.length; p++) {
        final nid = doc.resolvedNodes[PinRef(c.id, p)];
        if (nid == null) continue;
        final prev = netCurrentMag[nid] ?? 0.0;
        if (mag > prev) netCurrentMag[nid] = mag;
      }
    }

    for (final w in doc.wires) {
      final a = _pinWorld(w.from);
      final b = _pinWorld(w.to);
      if (a == null || b == null) continue;

      final nodeId = doc.resolvedNodes[w.from] ?? 0;
      final v = nodeVoltages[nodeId] ?? 0.0;
      final fFrom = _pinOutCurrent(w.from);
      final fTo = -_pinOutCurrent(w.to);
      final signedFlow = fFrom.abs() > 2e-5
          ? fFrom
          : (fTo.abs() > 2e-5 ? fTo : (netCurrentMag[nodeId] ?? 0.0));
      final flowMag = signedFlow.abs();

      var wireColor = v >= 0.3
          ? Color.lerp(colors.wireDefault, colors.accentAmber, (v / 5.0).clamp(0.0, 1.0))!
          : (v <= -0.3
              ? Color.lerp(colors.wireDefault, colors.scopeCh2, (-v / 5.0).clamp(0.0, 1.0))!
              : colors.wireDefault);
      if (v.abs() < 0.3 && flowMag > 2e-5) {
        wireColor = Color.lerp(colors.wireDefault, colors.componentStroke, 0.45)!;
      }

      final pts = routeWire(w, a, b);
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var k = 1; k < pts.length; k++) {
        path.lineTo(pts[k].dx, pts[k].dy);
      }

      canvas.drawPath(
        path,
        Paint()
          ..color = wireColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeJoin = StrokeJoin.round,
      );

      if (showFlow && flowMag > 2e-5) {
        _drawWireFlow(canvas, pts, signedFlow);
      }

      final ka = '${a.dx.round()},${a.dy.round()}';
      final kb = '${b.dx.round()},${b.dy.round()}';
      pinCounts[ka] = (pinCounts[ka] ?? 0) + 1;
      pinCounts[kb] = (pinCounts[kb] ?? 0) + 1;
    }

    for (final entry in pinCounts.entries) {
      if (entry.value >= 2) {
        final parts = entry.key.split(',');
        final pt = Offset(double.parse(parts[0]), double.parse(parts[1]));
        canvas.drawCircle(pt, 4.0, Paint()..color = colors.accentAmber);
      }
    }
  }

  void _drawWireFlow(Canvas canvas, List<Offset> pts, double signedCurrent) {
    final segs = <(Offset start, Offset delta, double len)>[];
    var totalLen = 0.0;
    for (var i = 0; i < pts.length - 1; i++) {
      final delta = pts[i + 1] - pts[i];
      final len = delta.distance;
      if (len >= 1.0) {
        segs.add((pts[i], delta, len));
        totalLen += len;
      }
    }
    if (totalLen < 8.0) return;

    const spacing = 30.0;
    final iMag = signedCurrent.abs();
    final speedFactor =
        (0.45 + 0.28 * (math.log(iMag / 1e-4) / math.ln10)).clamp(0.3, 2.2);
    final dir = signedCurrent >= 0 ? 1.0 : -1.0;
    final phase = ((animPhase * speedFactor * dir) % 1.0 + 1.0) % 1.0;

    final haloPaint = Paint()
      ..color = colors.canvasBackground.withAlpha(220)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final corePaint = Paint()
      ..color = Color.lerp(colors.accentAmber, Colors.white, 0.55)!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    var target = phase * spacing;
    while (target < totalLen) {
      var acc = 0.0;
      for (final (start, delta, len) in segs) {
        if (target <= acc + len) {
          final frac = (target - acc) / len;
          final pos = start + delta * frac;
          final unit = (delta / len) * dir;
          final perp = Offset(-unit.dy, unit.dx);
          final tip = pos + unit * 3.2;
          final w1 = pos - unit * 2.6 + perp * 3.4;
          final w2 = pos - unit * 2.6 - perp * 3.4;
          final chev = Path()
            ..moveTo(w1.dx, w1.dy)
            ..lineTo(tip.dx, tip.dy)
            ..lineTo(w2.dx, w2.dy);
          canvas.drawPath(chev, haloPaint);
          canvas.drawPath(chev, corePaint);
          break;
        }
        acc += len;
      }
      target += spacing;
    }
  }

  void _drawComponents(Canvas canvas) {
    final stroke = Paint()
      ..color = colors.componentStroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (final c in doc.components) {
      final center = Offset(c.gridX * kGridStep, c.gridY * kGridStep);
      final isSelected = c.id == selectedCompId || selectedCompIds.contains(c.id);

      if (isSelected) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: center, width: kGridStep * 3.4, height: kGridStep * 3.4),
            const Radius.circular(6),
          ),
          Paint()
            ..color = colors.accentAmber.withAlpha(110)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
      }

      if (overloadedIds.contains(c.id)) {
        canvas.drawCircle(center, kGridStep * 1.45, Paint()..color = colors.dangerRed.withAlpha(55));
      } else if (errCode == 3 &&
          (c.kind == CompKind.dcSource ||
              c.kind == CompKind.acSource ||
              c.kind == CompKind.funcGen ||
              c.kind == CompKind.powerRail ||
              c.kind == CompKind.pulseVoltage)) {
        canvas.drawCircle(
          center,
          kGridStep * 1.35,
          Paint()
            ..color = colors.dangerRed.withAlpha(150)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0,
        );
      }

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(c.rotation * math.pi * 0.5);
      if (c.flipX || c.flipY) {
        canvas.scale(c.flipX ? -1.0 : 1.0, c.flipY ? -1.0 : 1.0);
      }
      paintComponentSymbol(
        canvas: canvas,
        c: c,
        doc: doc,
        colors: colors,
        stroke: stroke,
        nodeVoltages: nodeVoltages,
        compCurrents: compCurrents,
        drawText: _drawCenteredText,
        blownFuseIds: blownFuseIds,
      );
      canvas.restore();

      for (var p = 0; p < c.pinOffsets.length; p++) {
        final pos = c.pinGridPos(p) * kGridStep;
        final ref = PinRef(c.id, p);
        final isPending = ref == pendingWirePin;
        final isFloating = errCode == 2 && errDetail > 0 && doc.resolvedNodes[ref] == errDetail;
        if (isFloating) {
          canvas.drawCircle(
            pos,
            9,
            Paint()
              ..color = colors.dangerRed.withAlpha(180)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.0,
          );
        }
        if (showPinHalos || isPending) {
          canvas.drawCircle(
            pos,
            isPending ? 10 : 7,
            Paint()
              ..color = (isPending ? colors.scopeCh2 : colors.pinHighlight).withAlpha(90)
              ..style = PaintingStyle.fill,
          );
        }
        canvas.drawCircle(
          pos,
          3.2,
          Paint()..color = isFloating ? colors.dangerRed : (isPending ? colors.scopeCh2 : colors.pinHighlight),
        );
      }

      if (c.fault != FaultType.none) {
        _drawBadge(
          canvas,
          center + const Offset(0, -kGridStep * 1.4),
          c.fault.name.toUpperCase(),
          colors.dangerRed,
        );
      } else if (blownFuseIds.contains(c.id)) {
        _drawBadge(
          canvas,
          center + const Offset(0, -kGridStep * 1.4),
          'BLOWN',
          colors.dangerRed,
        );
      } else if (overloadedIds.contains(c.id)) {
        _drawBadge(
          canvas,
          center + const Offset(0, -kGridStep * 1.4),
          'HOT',
          colors.dangerRed,
        );
      }
      if (showLabels &&
          c.kind != CompKind.ground &&
          c.kind != CompKind.logicProbe &&
          !(c.kind == CompKind.netPort && (c.hexPattern ?? '').startsWith('J'))) {
        _drawBadge(
          canvas,
          center + const Offset(0, kGridStep * 1.45),
          formatComponentBadge(c),
          colors.panelSurface.withAlpha(220),
          textColor: colors.componentStroke,
        );
      }
    }
  }

  void _drawProbes(Canvas canvas) {
    if (doc.probeCh1 != null) {
      final p = _pinWorld(doc.probeCh1!);
      if (p != null) _drawBadge(canvas, p + const Offset(0, -16), 'CH1', colors.scopeCh1);
    }
    if (doc.probeCh2 != null) {
      final p = _pinWorld(doc.probeCh2!);
      if (p != null) _drawBadge(canvas, p + const Offset(0, 16), 'CH2', colors.scopeCh2);
    }
    if (doc.probeCh3 != null) {
      final p = _pinWorld(doc.probeCh3!);
      if (p != null) _drawBadge(canvas, p + const Offset(-18, -14), 'CH3', colors.scopeCh3);
    }
    if (doc.probeCh4 != null) {
      final p = _pinWorld(doc.probeCh4!);
      if (p != null) {
        _drawBadge(
          canvas,
          p + const Offset(-18, 14),
          'CH4',
          colors.scopeCh4,
          textColor: Colors.black,
        );
      }
    }
  }

  void _drawNodeVoltages(Canvas canvas) {
    final seenNodes = <int>{};
    for (final entry in doc.resolvedNodes.entries) {
      final nid = entry.value;
      if (nid <= 0 || !seenNodes.add(nid)) continue;
      final p = _pinWorld(entry.key);
      if (p == null) continue;
      final v = nodeVoltages[nid] ?? 0.0;
      _drawBadge(
        canvas,
        p + const Offset(14, -12),
        '${v.toStringAsFixed(2)}V',
        colors.panelSurface.withAlpha(220),
        textColor: colors.accentAmber,
        cache: false,
      );
    }
  }

  static final Map<String, TextPainter> _textCache = {};

  TextPainter _cachedLayout(String text, Color color, double size, {bool cache = true}) {
    if (!cache) {
      return TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    }
    final key = '$text|${color.toARGB32()}|$size';
    return _textCache.putIfAbsent(key, () {
      if (_textCache.length > 128) {
        for (final tp in _textCache.values) {
          tp.dispose();
        }
        _textCache.clear();
      }
      return TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  void _drawBadge(
    Canvas canvas,
    Offset center,
    String text,
    Color bg, {
    Color textColor = Colors.black,
    bool cache = true,
  }) {
    final tp = _cachedLayout(text, textColor, 9, cache: cache);
    final rect = Rect.fromCenter(
      center: center,
      width: tp.width + 8,
      height: tp.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = bg,
    );
    tp.paint(canvas, center - Offset(tp.width * 0.5, tp.height * 0.5));
    if (!cache) tp.dispose();
  }

  void _drawCenteredText(
    Canvas canvas,
    String text,
    Offset center,
    Color color,
    double size, {
    bool cache = true,
  }) {
    final tp = _cachedLayout(text, color, size, cache: cache);
    tp.paint(canvas, center - Offset(tp.width * 0.5, tp.height * 0.5));
    if (!cache) tp.dispose();
  }

  @override
  bool shouldRepaint(covariant _SchematicPainter old) =>
      old.docRevision != docRevision ||
      old.colors != colors ||
      old.pan != pan ||
      old.scale != scale ||
      old.selectedCompId != selectedCompId ||
      old.selectedCompIds.length != selectedCompIds.length ||
      !old.selectedCompIds.containsAll(selectedCompIds) ||
      old.pendingWirePin != pendingWirePin ||
      old.showPinHalos != showPinHalos ||
      old.animPhase != animPhase ||
      old.showLabels != showLabels ||
      old.showNodeVoltages != showNodeVoltages ||
      old.showFlow != showFlow ||
      old.overloadedIds.length != overloadedIds.length ||
      !old.overloadedIds.containsAll(overloadedIds) ||
      old.blownFuseIds.length != blownFuseIds.length ||
      !old.blownFuseIds.containsAll(blownFuseIds) ||
      old.errCode != errCode ||
      old.errDetail != errDetail ||
      old.pendingWireCursor != pendingWireCursor ||
      old.hoverPin != hoverPin ||
      old.notesCount != notesCount ||
      old.selectionBox != selectionBox ||
      old.probeCh1 != probeCh1 ||
      old.probeCh2 != probeCh2 ||
      old.probeCh3 != probeCh3 ||
      old.probeCh4 != probeCh4 ||
      old.nodeVoltages != nodeVoltages ||
      old.compCurrents != compCurrents;
}
