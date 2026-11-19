import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../wear_shell.dart';

class WearWeightPicker extends StatefulWidget {
  const WearWeightPicker({super.key, required this.initial, required this.unit, required this.maximum});

  final String initial;
  final String unit;
  final double maximum;

  @override
  State<WearWeightPicker> createState() => _WearWeightPickerState();
}

class _WearWeightPickerState extends State<WearWeightPicker> {
  late final _controller = TextEditingController(text: widget.initial);

  double? get _value => double.tryParse(_controller.text.trim().replaceAll(',', '.'));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final value = _value;
    if (value != null && value.isFinite && value >= 0 && value <= widget.maximum) {
      Navigator.pop(context, value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.gc;
    final value = _value;
    return Scaffold(
      body: WearPage(
        scaleEdges: false,
        children: [
          Text(
            t.weightTitle(widget.unit),
            textAlign: TextAlign.center,
            style: AppTheme.f(15, weight: FontWeight.w800, color: gc.text),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(8)],
            textAlign: TextAlign.center,
            decoration: InputDecoration(isDense: true, suffixText: widget.unit),
            onTap: () {
              _controller.selection = TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
            },
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _confirm(),
          ),
          const SizedBox(height: 8),
          WearButton(
            label: t.save,
            icon: PhosphorIconsBold.check,
            filled: true,
            onTap: value != null && value.isFinite && value >= 0 && value <= widget.maximum ? _confirm : null,
          ),
          const SizedBox(height: 6),
          WearButton(label: t.cancel, icon: PhosphorIconsBold.caretLeft, onTap: () => Navigator.pop(context)),
        ],
      ),
    );
  }
}
