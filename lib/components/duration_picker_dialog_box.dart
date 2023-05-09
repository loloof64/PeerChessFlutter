/*
Adapted from the project 
https://github.com/ashutosh2014/duration_picker_dialog_box
*/

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

class Translations {
  final String duration;
  final String select;
  final String hours;
  final String minutes;
  final String seconds;
  final String incrementInSeconds;
  final String secondsUnit;

  const Translations({
    required this.duration,
    required this.select,
    required this.hours,
    required this.minutes,
    required this.seconds,
    required this.incrementInSeconds,
    required this.secondsUnit,
  });
}

const Duration _kDialAnimateDuration = Duration(milliseconds: 200);

const double _kDurationPickerWidthPortrait = 650.0;
const double _kDurationPickerWidthLandscape = 600.0;

const double _kDurationPickerHeightPortrait = 360.0;
const double _kDurationPickerHeightLandscape = 310.0;

const double _kTwoPi = 2 * math.pi;

enum DurationPickerMode { hour, minute, second, increment }

extension _DurationPickerModeExtenstion on DurationPickerMode {
  static const nextItems = {
    DurationPickerMode.hour: DurationPickerMode.minute,
    DurationPickerMode.minute: DurationPickerMode.second,
    DurationPickerMode.second: DurationPickerMode.increment,
    DurationPickerMode.increment: DurationPickerMode.hour,
  };
  static const prevItems = {
    DurationPickerMode.hour: DurationPickerMode.increment,
    DurationPickerMode.minute: DurationPickerMode.hour,
    DurationPickerMode.second: DurationPickerMode.minute,
    DurationPickerMode.increment: DurationPickerMode.second,
  };

  DurationPickerMode? get next => nextItems[this];

  DurationPickerMode? get prev => prevItems[this];
}

class _TappableLabel {
  _TappableLabel({
    required this.value,
    required this.painter,
    required this.onTap,
  });

  /// The value this label is displaying.
  final int value;

  /// Paints the text of the label.
  final TextPainter painter;

  /// Called when a tap gesture is detected on the label.
  final VoidCallback onTap;
}

class _DialPainterNew extends CustomPainter {
  _DialPainterNew({
    required this.primaryLabels,
    required this.secondaryLabels,
    required this.backgroundColor,
    required this.accentColor,
    required this.dotColor,
    required this.theta,
    required this.textDirection,
    required this.selectedValue,
  }) : super(repaint: PaintingBinding.instance.systemFonts);

  final List<_TappableLabel> primaryLabels;
  final List<_TappableLabel> secondaryLabels;
  final Color backgroundColor;
  final Color accentColor;
  final Color dotColor;
  final double theta;
  final TextDirection textDirection;
  final int selectedValue;

  static const double _labelPadding = 28.0;

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = size.shortestSide / 2.0;
    final Offset center = Offset(size.width / 2.0, size.height / 2.0);
    final Offset centerPoint = center;
    canvas.drawCircle(centerPoint, radius, Paint()..color = backgroundColor);

    final double labelRadius = radius - _labelPadding;
    Offset getOffsetForTheta(double theta) {
      return center +
          Offset(labelRadius * math.cos(theta), -labelRadius * math.sin(theta));
    }

    void paintLabels(List<_TappableLabel> labels) {
      final double labelThetaIncrement = -_kTwoPi / labels.length;
      double labelTheta = math.pi / 2.0;

      for (final _TappableLabel label in labels) {
        final TextPainter labelPainter = label.painter;
        final Offset labelOffset =
            Offset(-labelPainter.width / 2.0, -labelPainter.height / 2.0);
        labelPainter.paint(canvas, getOffsetForTheta(labelTheta) + labelOffset);
        labelTheta += labelThetaIncrement;
      }
    }

    paintLabels(primaryLabels);

    final Paint selectorPaint = Paint()..color = accentColor;
    final Offset focusedPoint = getOffsetForTheta(theta);
    const double focusedRadius = _labelPadding - 4.0;
    canvas.drawCircle(centerPoint, 4.0, selectorPaint);
    canvas.drawCircle(focusedPoint, focusedRadius, selectorPaint);
    selectorPaint.strokeWidth = 2.0;
    canvas.drawLine(centerPoint, focusedPoint, selectorPaint);

    // Add a dot inside the selector but only when it isn't over the labels.
    // This checks that the selector's theta is between two labels. A remainder
    // between 0.1 and 0.45 indicates that the selector is roughly not above any
    // labels. The values were derived by manually testing the dial.
    int len = primaryLabels.length;
    //len = 14;
    final double labelThetaIncrement = -_kTwoPi / len;
    bool flag = len == 10
        ? !(theta % labelThetaIncrement > 0.25 &&
            theta % labelThetaIncrement < 0.4)
        : (theta % labelThetaIncrement > 0.1 &&
            theta % labelThetaIncrement < 0.45);
    if (flag) {
      canvas.drawCircle(focusedPoint, 2.0, selectorPaint..color = dotColor);
    }

    final Rect focusedRect = Rect.fromCircle(
      center: focusedPoint,
      radius: focusedRadius,
    );
    canvas
      ..save()
      ..clipPath(Path()..addOval(focusedRect));
    paintLabels(secondaryLabels);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DialPainterNew oldPainter) {
    return oldPainter.primaryLabels != primaryLabels ||
        oldPainter.secondaryLabels != secondaryLabels ||
        oldPainter.backgroundColor != backgroundColor ||
        oldPainter.accentColor != accentColor ||
        oldPainter.theta != theta;
  }
}

class _Dial extends StatefulWidget {
  const _Dial({
    required this.value,
    required this.mode,
    required this.onChanged,
  });

  final int value;
  final DurationPickerMode mode;
  final ValueChanged<int> onChanged;

  @override
  _DialState createState() => _DialState();
}

class _DialState extends State<_Dial> with SingleTickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    _thetaController = AnimationController(
      duration: _kDialAnimateDuration,
      vsync: this,
    );
    _thetaTween = Tween<double>(begin: _getThetaForTime(widget.value));
    _theta = _thetaController!
        .drive(CurveTween(curve: standardEasing))
        .drive(_thetaTween!)
      ..addListener(() => setState(() {
            /* _theta.value has changed */
          }));
  }

  ThemeData? themeData;
  MaterialLocalizations? localizations;
  MediaQueryData? media;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    assert(debugCheckHasMediaQuery(context));
    themeData = Theme.of(context);
    localizations = MaterialLocalizations.of(context);
    media = MediaQuery.of(context);
  }

  @override
  void didUpdateWidget(_Dial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.mode != oldWidget.mode || widget.value != oldWidget.value) {
      if (!_dragging) _animateTo(_getThetaForTime(widget.value));
    }
  }

  @override
  void dispose() {
    _thetaController!.dispose();
    super.dispose();
  }

  Tween<double>? _thetaTween;
  Animation<double>? _theta;
  AnimationController? _thetaController;
  bool _dragging = false;

  static double _nearest(double target, double a, double b) {
    return ((target - a).abs() < (target - b).abs()) ? a : b;
  }

  void _animateTo(double targetTheta) {
    final double currentTheta = _theta!.value;
    double beginTheta =
        _nearest(targetTheta, currentTheta, currentTheta + _kTwoPi);
    beginTheta = _nearest(targetTheta, beginTheta, currentTheta - _kTwoPi);
    _thetaTween!
      ..begin = beginTheta
      ..end = targetTheta;
    _thetaController!
      ..value = 0.0
      ..forward();
  }

  double _getThetaForTime(int value) {
    double fraction;
    switch (widget.mode) {
      case DurationPickerMode.hour:
        fraction = (value / Duration.hoursPerDay) % Duration.hoursPerDay;
        break;
      case DurationPickerMode.minute:
        fraction = (value / Duration.minutesPerHour) % Duration.minutesPerHour;
        break;
      case DurationPickerMode.second:
        fraction =
            (value / Duration.secondsPerMinute) % Duration.secondsPerMinute;
        break;
      case DurationPickerMode.increment:
        fraction =
            (value / Duration.secondsPerMinute) % Duration.secondsPerMinute;
        break;
      default:
        fraction = -1;
        break;
    }
    return (math.pi / 2.0 - fraction * _kTwoPi) % _kTwoPi;
  }

  int _getTimeForTheta(double theta) {
    final double fraction = (0.25 - (theta % _kTwoPi) / _kTwoPi) % 1.0;
    int result;
    switch (widget.mode) {
      case DurationPickerMode.hour:
        result =
            (fraction * Duration.hoursPerDay).round() % Duration.hoursPerDay;
        break;
      case DurationPickerMode.minute:
        result = (fraction * Duration.minutesPerHour).round() %
            Duration.minutesPerHour;
        break;
      case DurationPickerMode.second:
        result = (fraction * Duration.secondsPerMinute).round() %
            Duration.secondsPerMinute;
        break;
      case DurationPickerMode.increment:
        result = (fraction * Duration.secondsPerMinute).round() %
            Duration.secondsPerMinute;
        break;
      default:
        result = -1;
        break;
    }
    return result;
  }

  int _notifyOnChangedIfNeeded() {
    final int current = _getTimeForTheta(_theta!.value);
    if (current != widget.value) widget.onChanged(current);
    return current;
  }

  void _updateThetaForPan({bool roundMinutes = false}) {
    setState(() {
      final Offset offset = _position! - _center!;
      double angle =
          (math.atan2(offset.dx, offset.dy) - math.pi / 2.0) % _kTwoPi;
      if (roundMinutes) {
        angle = _getThetaForTime(_getTimeForTheta(angle));
      }
      _thetaTween!
        ..begin = angle
        ..end = angle;
    });
  }

  Offset? _position;
  Offset? _center;

  void _handlePanStart(DragStartDetails details) {
    assert(!_dragging);
    _dragging = true;
    final RenderBox box = context.findRenderObject() as RenderBox;
    _position = box.globalToLocal(details.globalPosition);
    _center = box.size.center(Offset.zero);
    _updateThetaForPan();
    _notifyOnChangedIfNeeded();
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    _position = _position! + details.delta;
    _updateThetaForPan();
    _notifyOnChangedIfNeeded();
  }

  void _handlePanEnd(DragEndDetails details) {
    assert(_dragging);
    _dragging = false;
    _position = null;
    _center = null;
    _animateTo(_getThetaForTime(widget.value));
  }

  void _handleTapUp(TapUpDetails details) {
    final RenderBox box = context.findRenderObject() as RenderBox;
    _position = box.globalToLocal(details.globalPosition);
    _center = box.size.center(Offset.zero);
    _updateThetaForPan(roundMinutes: true);
    final int newValue = _notifyOnChangedIfNeeded();

    _announceToAccessibility(context, localizations!.formatDecimal(newValue));
    _animateTo(_getThetaForTime(_getTimeForTheta(_theta!.value)));
    _dragging = false;

    _position = null;
    _center = null;
  }

  void _selectValue(int value) {
    _announceToAccessibility(context, localizations!.formatDecimal(value));
    final double angle = _getThetaForTime(widget.value);
    _thetaTween!
      ..begin = angle
      ..end = angle;
    _notifyOnChangedIfNeeded();
  }

  static const List<int> _twentyFourHours = <int>[
    0,
    2,
    4,
    6,
    8,
    10,
    12,
    14,
    16,
    18,
    20,
    22
  ];

  _TappableLabel _buildTappableLabel(TextTheme textTheme, Color color,
      int value, String label, VoidCallback onTap) {
    final TextStyle style = textTheme.bodyLarge!.copyWith(color: color);
    final double labelScaleFactor =
        math.min(MediaQuery.of(context).textScaleFactor, 2.0);
    return _TappableLabel(
      value: value,
      painter: TextPainter(
        text: TextSpan(style: style, text: label),
        textDirection: TextDirection.ltr,
        textScaleFactor: labelScaleFactor,
      )..layout(),
      onTap: onTap,
    );
  }

  List<_TappableLabel> _build24HourRing(TextTheme textTheme, Color color) =>
      <_TappableLabel>[
        for (final int hour in _twentyFourHours)
          _buildTappableLabel(
            textTheme,
            color,
            hour,
            hour.toString(),
            () {
              _selectValue(hour);
            },
          ),
      ];

  List<_TappableLabel> _buildMinutes(TextTheme textTheme, Color color) {
    const List<int> minuteMarkerValues = <int>[
      0,
      5,
      10,
      15,
      20,
      25,
      30,
      35,
      40,
      45,
      50,
      55
    ];

    return <_TappableLabel>[
      for (final int minute in minuteMarkerValues)
        _buildTappableLabel(
          textTheme,
          color,
          minute,
          minute.toString(),
          () {
            _selectValue(minute);
          },
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TimePickerThemeData pickerTheme = TimePickerTheme.of(context);
    final Color backgroundColor = pickerTheme.dialBackgroundColor ??
        themeData!.colorScheme.onBackground.withOpacity(0.12);
    final Color accentColor =
        pickerTheme.dialHandColor ?? themeData!.colorScheme.primary;
    final Color primaryLabelColor = MaterialStateProperty.resolveAs(
            pickerTheme.dialTextColor, <MaterialState>{}) ??
        themeData!.colorScheme.onSurface;
    final Color secondaryLabelColor = MaterialStateProperty.resolveAs(
            pickerTheme.dialTextColor,
            <MaterialState>{MaterialState.selected}) ??
        themeData!.colorScheme.onPrimary;
    List<_TappableLabel> primaryLabels;
    List<_TappableLabel> secondaryLabels;
    int selectedDialValue;
    switch (widget.mode) {
      case DurationPickerMode.hour:
        selectedDialValue = widget.value;
        primaryLabels = _build24HourRing(theme.textTheme, primaryLabelColor);
        secondaryLabels =
            _build24HourRing(theme.textTheme, secondaryLabelColor);
        break;
      case DurationPickerMode.minute:
        selectedDialValue = widget.value;
        primaryLabels = _buildMinutes(theme.textTheme, primaryLabelColor);
        secondaryLabels = _buildMinutes(theme.textTheme, secondaryLabelColor);
        break;
      case DurationPickerMode.second:
        selectedDialValue = widget.value;
        primaryLabels = _buildMinutes(theme.textTheme, primaryLabelColor);
        secondaryLabels = _buildMinutes(theme.textTheme, secondaryLabelColor);
        break;
      case DurationPickerMode.increment:
        selectedDialValue = widget.value;
        primaryLabels = _buildMinutes(theme.textTheme, primaryLabelColor);
        secondaryLabels = _buildMinutes(theme.textTheme, secondaryLabelColor);
        break;
      default:
        selectedDialValue = -1;
        primaryLabels = <_TappableLabel>[];
        secondaryLabels = <_TappableLabel>[];
    }

    return GestureDetector(
      excludeFromSemantics: true,
      onPanStart: _handlePanStart,
      onPanUpdate: _handlePanUpdate,
      onPanEnd: _handlePanEnd,
      onTapUp: _handleTapUp,
      child: CustomPaint(
        key: const ValueKey<String>('duration-picker-dial'),
        painter: _DialPainterNew(
          selectedValue: selectedDialValue,
          primaryLabels: primaryLabels,
          secondaryLabels: secondaryLabels,
          backgroundColor: backgroundColor,
          accentColor: accentColor,
          dotColor: theme.colorScheme.surface,
          theta: _theta!.value,
          textDirection: Directionality.of(context),
        ),
      ),
    );
  }
}

/// A duration picker designed to appear inside a popup dialog.
///
/// Pass this widget to [showDialog]. The value returned by [showDialog] is the
/// selected [Duration] if the user taps the "OK" button, or null if the user
/// taps the "CANCEL" button. The selected time is reported by calling
/// [Navigator.pop].
class _DurationPickerDialog extends StatefulWidget {
  /// Creates a duration picker.
  ///
  /// [initialTime] must not be null.
  const _DurationPickerDialog({
    Key? key,
    required this.initialDuration,
    required this.translations,
    this.cancelText,
    this.confirmText,
    this.showHead = true,
    this.durationPickerMode,
  }) : super(key: key);

  final Translations translations;

  /// The duration initially selected when the dialog is shown.
  final ExtendedDuration initialDuration;

  /// Optionally provide your own text for the cancel button.
  ///
  /// If null, the button uses [MaterialLocalizations.cancelButtonLabel].
  final String? cancelText;

  /// Optionally provide your own text for the confirm button.
  ///
  /// If null, the button uses [MaterialLocalizations.okButtonLabel].
  final String? confirmText;

  final bool showHead;

  final DurationPickerMode? durationPickerMode;

  @override
  _DurationPickerState createState() => _DurationPickerState();
}

class _DurationPickerState extends State<_DurationPickerDialog> {
  ExtendedDuration? get selectedDuration => _selectedDuration;
  ExtendedDuration? _selectedDuration;

  @override
  void initState() {
    super.initState();
    _selectedDuration = widget.initialDuration;
  }

  void _handleDurationChanged(ExtendedDuration value) {
    setState(() {
      _selectedDuration = value;
    });
  }

  void _handleCancel() {
    Navigator.pop(context);
  }

  void _handleOk() {
    Navigator.pop(
      context,
      _selectedDuration ??
          const ExtendedDuration(
            duration: Duration(),
            incrementInSeconds: 0,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MaterialLocalizations localizations =
        MaterialLocalizations.of(context);
    final ThemeData theme = Theme.of(context);

    /// Duration Head with heading as Duration.
    final Widget head = Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        widget.translations.duration.toUpperCase(),
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w400,
        ),
      ),
    );

    /// Duration Picker Widget.
    final Widget picker = Padding(
        padding:
            const EdgeInsets.only(left: 16.0, right: 16, top: 8, bottom: 8),
        child: DurationPicker(
          duration: _selectedDuration ??
              const ExtendedDuration(
                duration: Duration.zero,
                incrementInSeconds: 0,
              ),
          onChange: _handleDurationChanged,
          translations: widget.translations,
        ));

    /// Action Buttons - Cancel and OK
    final Widget actions = Container(
      alignment: AlignmentDirectional.centerEnd,
      constraints: const BoxConstraints(minHeight: 42.0),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: OverflowBar(
        spacing: 2,
        overflowAlignment: OverflowBarAlignment.end,
        children: <Widget>[
          ElevatedButton(
            onPressed: _handleOk,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.greenAccent,
            ),
            child: Padding(
              padding: const EdgeInsets.all(4.0),
              child: Text(
                widget.confirmText ?? localizations.okButtonLabel,
                style: const TextStyle(
                  color: Colors.white,
                ),
              ),
            ),
          ),
          ElevatedButton(
            onPressed: _handleCancel,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
            ),
            child: Padding(
              padding: const EdgeInsets.all(4.0),
              child: Text(
                widget.cancelText ?? localizations.cancelButtonLabel,
                style: const TextStyle(
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    /// Widget with Head as Duration, Duration Picker Widget and Dialog as Actions - Cancel and OK.
    final Widget pickerAndActions = Container(
      color: theme.dialogBackgroundColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          widget.showHead ? head : Container(),
          Expanded(child: picker),
          // picker grows and shrinks with the available space
          actions,
        ],
      ),
    );

    final Dialog dialog = Dialog(child: OrientationBuilder(
        builder: (BuildContext context, Orientation orientation) {
      switch (orientation) {
        case Orientation.portrait:
          return SizedBox(
              width: _kDurationPickerWidthPortrait,
              height: _kDurationPickerHeightPortrait,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      child: pickerAndActions,
                    ),
                  ]));
        case Orientation.landscape:
          return SizedBox(
              width: widget.showHead
                  ? _kDurationPickerWidthLandscape
                  : _kDurationPickerWidthLandscape,
              height: widget.showHead
                  ? _kDurationPickerHeightLandscape + 28
                  : _kDurationPickerHeightLandscape,
              child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Flexible(
                      child: pickerAndActions,
                    ),
                  ]));
      }
    }));

    return Theme(
      data: theme.copyWith(
        dialogBackgroundColor: Colors.transparent,
      ),
      child: dialog,
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}

void _announceToAccessibility(BuildContext context, String message) {
  SemanticsService.announce(message, Directionality.of(context));
}

class ExtendedDuration {
  final Duration duration;
  final int incrementInSeconds;

  const ExtendedDuration({
    required this.duration,
    required this.incrementInSeconds,
  });
}

/// Shows a dialog containing the duration picker.
///
/// The returned Future resolves to the duration selected by the user when the user
/// closes the dialog. If the user cancels the dialog, null is returned.
///
/// To show a dialog with [initialDuration] equal to the Duration with 0 milliseconds:
/// To show a dialog with [DurationPickerMode] equal to the Duration Mode like hour, second,etc.:
/// To show a dialog with [showHead] equal to boolean (Default is true) to show Head as Duration:
///
/// Optionally provide your own text for the confirm button [confirmText.
/// If null, the button uses [MaterialLocalizations.okButtonLabel].
///
/// Optionally provide your own text for the cancel button [cancelText].
/// If null, the button uses [MaterialLocalizations.cancelButtonLabel].
///
/// ```dart
/// showDurationPicker(
///   initialDuration: initialDuration,
///   durationPickerMode: durationPickerMode,
///   showHead: showHead,
///   confirmText: confirmText,
///   cancelText: cancelText,
///    );
/// ```
Future<ExtendedDuration?> showDurationPicker(
    {required BuildContext context,
    required ExtendedDuration initialDuration,
    required Translations translations,
    DurationPickerMode? durationPickerMode,
    bool showHead = true,
    String? confirmText,
    String? cancelText}) async {
  return await showDialog<ExtendedDuration>(
    context: context,
    builder: (BuildContext context) => _DurationPickerDialog(
      initialDuration: initialDuration,
      durationPickerMode: durationPickerMode,
      showHead: showHead,
      confirmText: confirmText,
      cancelText: cancelText,
      translations: translations,
    ),
  );
}

/// A Widget for duration picker.
///
/// [duration] - a initial Duration for Duration Picker when not provided initialize with Duration().
/// [onChange] - a function to be called when duration changed and cannot be null.
/// [durationPickerMode] - Duration Picker Mode to show Widget with Days,  Hours, Minutes, Seconds, Milliseconds, Microseconds, By default Duration Picker Mode is Minute.
/// [width] -  Width of Duration Picker Widget and can be null.
/// [height] -  Height of Duration Picker Widget and can be null.
///
/// ```dart
/// DurationPicker(
///   duration: Duration(),
///   onChange: onChange,
///   height: 600,
///   width: 700
/// );
/// ```
class DurationPicker extends StatefulWidget {
  final ExtendedDuration duration;
  final ValueChanged<ExtendedDuration> onChange;
  final DurationPickerMode? durationPickerMode;

  final Translations translations;

  final double? width;
  final double? height;

  const DurationPicker({
    super.key,
    required this.translations,
    required this.duration,
    required this.onChange,
    this.width,
    this.height,
    this.durationPickerMode,
  });

  @override
  DurationPickerState createState() => DurationPickerState();
}

class DurationPickerState extends State<DurationPicker> {
  late DurationPickerMode currentDurationType;
  var boxShadow = const BoxShadow(
      color: Color(0x07000000), offset: Offset(3, 0), blurRadius: 12);
  int hours = 0;
  int minutes = 0;
  int seconds = 0;
  int incrementSeconds = 0;
  int currentValue = 0;
  Duration duration = const Duration();
  double? width;

  double? height;

  @override
  void initState() {
    super.initState();
    currentDurationType =
        widget.durationPickerMode ?? DurationPickerMode.minute;
    hours = (widget.duration.duration.inHours) % Duration.hoursPerDay;
    minutes = widget.duration.duration.inMinutes % Duration.minutesPerHour;
    seconds = widget.duration.duration.inSeconds % Duration.secondsPerMinute;
    incrementSeconds = widget.duration.incrementInSeconds;
    currentValue = getCurrentValue();

    width = widget.width ?? _kDurationPickerWidthLandscape;
    height = widget.height ?? _kDurationPickerHeightLandscape;
  }

  @override
  Widget build(BuildContext context) {
    return OrientationBuilder(builder: (context, orientation) {
      return SizedBox(
          width: width,
          height: height,
          child: Row(children: [
            Expanded(flex: 5, child: getDurationFields(context, orientation)),
            Expanded(
                flex: 5,
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 350,
                        height: 200,
                        child: _Dial(
                          value: currentValue,
                          mode: currentDurationType,
                          onChanged: updateDurationFields,
                        ),
                      ),
                      getFields(),
                    ])),
          ]));
    });
  }

  Widget getFields() {
    return Flexible(
        child: Container(
            padding: const EdgeInsets.only(left: 10, right: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(200),
                      color: Colors.blueAccent),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    hoverColor: Colors.transparent,
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    focusColor: Colors.transparent,
                    onTap: () {
                      updateValue(currentDurationType.prev);
                    },
                    child: const Icon(
                      Icons.arrow_left_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
                Text(
                  getCurrentTimeTypeString(),
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 16),
                ),
                Container(
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(200),
                      color: Colors.blueAccent),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    hoverColor: Colors.transparent,
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    focusColor: Colors.transparent,
                    onTap: () {
                      updateValue(currentDurationType.next);
                    },
                    child: const Icon(
                      Icons.arrow_right_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
              ],
            )));
  }

  String getCurrentTimeTypeString() {
    switch (currentDurationType) {
      case DurationPickerMode.hour:
        return widget.translations.hours;
      case DurationPickerMode.minute:
        return widget.translations.minutes;
      case DurationPickerMode.second:
        return widget.translations.seconds;
      case DurationPickerMode.increment:
        return widget.translations.incrementInSeconds;
    }
  }

  Widget getCurrentSelectionFieldText() {
    final selectString = widget.translations.select;
    return SizedBox(
        width: double.infinity,
        child: Text(
          "${selectString.toUpperCase()} ${getCurrentTimeTypeString().toUpperCase()}",
          style: TextStyle(color: Theme.of(context).colorScheme.primary),
          textAlign: TextAlign.left,
        ));
  }

  Widget getDurationFields(BuildContext context, Orientation orientation) {
    return Container(
        padding: const EdgeInsets.only(left: 10, right: 10),
        width: 100,
        child: Column(
          children: <Widget>[
            getCurrentSelectionFieldText(),
            const SizedBox(
              height: 10,
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ShowTimeArgs(
                  durationMode: DurationPickerMode.hour,
                  onChanged: updateValue,
                  onTextChanged: updateDurationFields,
                  value: hours,
                  formatWidth: 2,
                  desc: widget.translations.hours,
                  isEditable: currentDurationType == DurationPickerMode.hour,
                  start: 0,
                  end: 23,
                ),
                getColonWidget(),
                _ShowTimeArgs(
                  durationMode: DurationPickerMode.minute,
                  onChanged: updateValue,
                  onTextChanged: updateDurationFields,
                  value: minutes,
                  formatWidth: 2,
                  desc: widget.translations.minutes,
                  isEditable: currentDurationType == DurationPickerMode.minute,
                  start: 0,
                  end: 59,
                ),
                getColonWidget(),
                _ShowTimeArgs(
                  durationMode: DurationPickerMode.second,
                  onChanged: updateValue,
                  onTextChanged: updateDurationFields,
                  value: seconds,
                  formatWidth: 2,
                  desc: widget.translations.seconds,
                  isEditable: currentDurationType == DurationPickerMode.second,
                  start: 0,
                  end: 59,
                ),
                getPlusWidget(),
                _ShowTimeArgs(
                  durationMode: DurationPickerMode.increment,
                  onChanged: updateValue,
                  onTextChanged: updateDurationFields,
                  value: incrementSeconds,
                  formatWidth: 2,
                  desc: widget.translations.incrementInSeconds,
                  isEditable:
                      currentDurationType == DurationPickerMode.increment,
                  start: 0,
                  end: 59,
                ),
                getSecondWidget(),
              ],
            ),
            const SizedBox(
              width: 2,
              height: 4,
            ),
            currentDurationType == DurationPickerMode.hour &&
                    orientation == Orientation.landscape
                ? getFields()
                : Container()
          ],
        ));
  }

  int getCurrentValue() {
    switch (currentDurationType) {
      case DurationPickerMode.hour:
        return hours;
      case DurationPickerMode.minute:
        return minutes;
      case DurationPickerMode.second:
        return seconds;
      case DurationPickerMode.increment:
        return incrementSeconds;
      default:
        return -1;
    }
  }

  void updateDurationFields(value) {
    setState(() {
      switch (currentDurationType) {
        case DurationPickerMode.hour:
          hours = value;
          break;
        case DurationPickerMode.minute:
          minutes = value;
          break;
        case DurationPickerMode.second:
          seconds = value;
          break;
        case DurationPickerMode.increment:
          incrementSeconds = value;
      }
      currentValue = value;
    });

    widget.onChange(
      ExtendedDuration(
        duration: Duration(
          days: 0,
          hours: hours,
          minutes: minutes,
          seconds: seconds,
          milliseconds: 0,
          microseconds: 0,
        ),
        incrementInSeconds: incrementSeconds,
      ),
    );
  }

  void updateValue(value) {
    setState(() {
      currentDurationType = value;
      currentValue = getCurrentValue();
      width = getWidth(currentDurationType);
    });
  }

  double? getWidth(durationType) {
    return width == _kDurationPickerWidthLandscape ? width : width! * 2;
  }

  Widget getColonWidget() {
    return Row(children: const [
      SizedBox(
        width: 4,
      ),
      Text(
        ":",
        style:
            TextStyle(fontWeight: FontWeight.bold, fontSize: 28, height: 1.25),
      ),
      SizedBox(
        width: 4,
      )
    ]);
  }

  Widget getPlusWidget() {
    return Row(children: const [
      SizedBox(
        width: 4,
      ),
      Text(
        "+",
        style:
            TextStyle(fontWeight: FontWeight.bold, fontSize: 28, height: 1.25),
      ),
      SizedBox(
        width: 4,
      )
    ]);
  }

  Widget getSecondWidget() {
    return Row(children: [
      const SizedBox(
        width: 1.5,
      ),
      Text(
        widget.translations.secondsUnit,
        style: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 28, height: 1.25),
      ),
      const SizedBox(
        width: 4,
      ),
    ]);
  }

  String getFormattedStringWithLeadingZeros(int number, int formatWidth) {
    var result = StringBuffer();
    while (formatWidth > 0) {
      int temp = number % 10;
      result.write(temp);
      number = (number ~/ 10);
      formatWidth--;
    }
    return result.toString();
  }
}

class _ShowTimeArgs extends StatefulWidget {
  final int value;
  final int formatWidth;
  final String desc;
  final bool isEditable;
  final DurationPickerMode durationMode;
  final Function onChanged;
  final Function onTextChanged;
  final int start;
  final int end;

  const _ShowTimeArgs(
      {required this.value,
      required this.formatWidth,
      required this.desc,
      required this.isEditable,
      required this.durationMode,
      required this.onChanged,
      required this.onTextChanged,
      required this.start,
      required this.end});

  @override
  _ShowTimeArgsState createState() => _ShowTimeArgsState();
}

class _ShowTimeArgsState extends State<_ShowTimeArgs> {
  TextEditingController? controller;
  var timerColor = const Color(0x1E000000);
  dynamic boxShadow;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    controller = getTextEditingController(getFormattedText());
  }

  @override
  void initState() {
    super.initState();
    controller = getTextEditingController(getFormattedText());
  }

  @override
  void didUpdateWidget(_ShowTimeArgs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      controller = getTextEditingController(getFormattedText());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    return Column(children: [
      widget.isEditable
          ? SizedBox(
              width: getTextFormFieldWidth(widget.durationMode),
              height: 41,
              child: RawKeyboardListener(
                  focusNode: FocusNode(),
                  onKey: (event) {
                    if (event.runtimeType == RawKeyDownEvent) {
                      switch (event.logicalKey.keyId) {
                        case 4295426091: //Enter Key ID from keyboard
                          widget.onChanged(widget.durationMode.next);
                          break;
                        case 4295426130:
                          widget.onTextChanged(
                              (widget.value + 1) % (widget.end + 1) +
                                  widget.start);
                          break;
                        case 4295426129:
                          widget.onTextChanged(
                              (widget.value - 1) % (widget.end + 1) +
                                  widget.start);
                          break;
                      }
                    }
                  },
                  child: TextFormField(
                    onChanged: (text) {
                      if (text.trim() == "") {
                        text = "0";
                      }
                      widget.onTextChanged(int.parse(text));
                    },
                    inputFormatters: [
                      FilteringTextInputFormatter.deny('\n'),
                      FilteringTextInputFormatter.deny('\t'),
                      _DurationFieldsFormatter(
                        start: widget.start,
                        end: widget.end,
                        useFinal:
                            widget.durationMode != DurationPickerMode.hour,
                      )
                    ],
                    style: const TextStyle(fontSize: 20),
                    controller: controller,
                    decoration: InputDecoration(
                      contentPadding:
                          const EdgeInsets.only(left: 10, right: 10),
                      filled: true,
                      enabledBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.transparent),
                      ),
                      errorBorder: OutlineInputBorder(
                        borderSide:
                            BorderSide(color: colorScheme.error, width: 2.0),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide:
                            BorderSide(color: colorScheme.primary, width: 2.0),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderSide:
                            BorderSide(color: colorScheme.error, width: 2.0),
                      ),
                      errorStyle: const TextStyle(
                          fontSize: 0.0,
                          height:
                              0.0), // Prevent the error text from appearing.
                    ),
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    textAlign: TextAlign.center,
                  )))
          : InkWell(
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              focusColor: Colors.transparent,
              onTap: () async {
                widget.onChanged(widget.durationMode);
                timerColor = const Color(0x1E000000);
              },
              onHover: (hoverCursor) {
                setState(() {
                  boxShadow = hoverCursor
                      ? const BoxShadow(
                          color: Color(0x30004CBE),
                          offset: Offset(0, 6),
                          blurRadius: 12)
                      : const BoxShadow(
                          color: Color(0x07000000),
                          offset: Offset(3, 0),
                          blurRadius: 12);
                  timerColor = hoverCursor
                      ? const Color(0x32000000)
                      : const Color(0x1E000000);
                });
              },
              child: Container(
                constraints: const BoxConstraints(maxWidth: 150),
                padding:
                    const EdgeInsets.only(left: 6, right: 6, top: 4, bottom: 4),
                decoration: BoxDecoration(
                  color: timerColor,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  widget.durationMode != DurationPickerMode.hour
                      ? getFormattedStringWithLeadingZeros(
                          widget.value, widget.formatWidth)
                      : widget.value.toString().padLeft(2, '0'),
                  style: const TextStyle(
                    fontSize: 28,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
      Text(
        widget.desc,
        style: const TextStyle(fontSize: 12, height: 1.5),
      )
    ]);
  }

  double getTextFormFieldWidth(currentDurationField) {
    switch (currentDurationField) {
      case DurationPickerMode.hour:
      case DurationPickerMode.minute:
      case DurationPickerMode.second:
      case DurationPickerMode.increment:
        return 45;
      default:
        return 0;
    }
  }

  String getFormattedText() {
    return widget.value.toString();
  }

  TextEditingController getTextEditingController(value) {
    return TextEditingController.fromValue(TextEditingValue(
        text: value, selection: TextSelection.collapsed(offset: value.length)));
  }

  String getFormattedStringWithLeadingZeros(int number, int formatWidth) {
    var result = StringBuffer();
    while (formatWidth > 0) {
      int temp = number % 10;
      result.write(temp);
      number = (number ~/ 10);
      formatWidth--;
    }
    return result.toString().split('').reversed.join();
  }
}

class _DurationFieldsFormatter extends TextInputFormatter {
  final int? start;
  final int? end;
  final bool? useFinal;

  _DurationFieldsFormatter({this.start, this.end, this.useFinal});

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String text = newValue.text;
    int selectionIndex = newValue.selection.end;
    int value = 0;
    try {
      if (text.trim() != "") {
        value = int.parse(text);
      }
    } catch (ex) {
      return oldValue;
    }

    if (value == 0) {
      return newValue;
    }

    if (!(start! <= value && (!useFinal! || value <= end!))) {
      return oldValue;
    }
    return newValue.copyWith(
      text: value.toString(),
      selection: TextSelection.collapsed(offset: selectionIndex),
    );
  }
}
