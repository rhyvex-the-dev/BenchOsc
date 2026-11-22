import 'circuit_doc.dart';

/// Reusable named macro/subcircuit block built from a selected sub-schematic.
class SubcircuitDef {
  final String name;
  final List<PlacedComponent> components;
  final List<WireLink> wires;
  /// External interface terminals referencing internal component pins.
  final List<PinRef> externalPins;
  final List<String> pinLabels;

  const SubcircuitDef({
    required this.name,
    required this.components,
    required this.wires,
    required this.externalPins,
    required this.pinLabels,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'components': components.map((c) => c.toJson()).toList(),
        'wires': wires.map((w) => w.toJson()).toList(),
        'externalPins': externalPins.map((p) => p.toJson()).toList(),
        'pinLabels': pinLabels,
      };

  factory SubcircuitDef.fromJson(Map<String, dynamic> j) => SubcircuitDef(
        name: j['name'] as String,
        components: (j['components'] as List<dynamic>)
            .map((e) => PlacedComponent.fromJson(e as Map<String, dynamic>))
            .toList(),
        wires: (j['wires'] as List<dynamic>)
            .map((e) => WireLink.fromJson(e as Map<String, dynamic>))
            .toList(),
        externalPins: (j['externalPins'] as List<dynamic>)
            .map((e) => PinRef.fromJson(e as Map<String, dynamic>))
            .toList(),
        pinLabels: (j['pinLabels'] as List<dynamic>).cast<String>(),
      );
}
