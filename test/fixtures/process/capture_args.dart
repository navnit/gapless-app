import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  final output = File(arguments.first);
  output.writeAsStringSync(jsonEncode(arguments.skip(1).toList()), flush: true);
}
