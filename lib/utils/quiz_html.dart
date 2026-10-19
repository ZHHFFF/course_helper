/// Extract a JSON array/object assigned to a script variable. Track nested
/// containers and JSON strings so question text such as "];" is not truncated.
String? extractQuizJson(String html, String variable) {
  final assignment = RegExp(
    r'\b' + RegExp.escape(variable) + r'\s*=\s*(?=[\[{])',
  ).firstMatch(html);
  if (assignment == null) return null;
  final start = assignment.end;
  final closers = <int>[];
  var inString = false;
  var escaped = false;
  for (var i = start; i < html.length; i++) {
    final char = html.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char == 92) {
        escaped = true;
      } else if (char == 34) {
        inString = false;
      }
      continue;
    }
    if (char == 34) {
      inString = true;
    } else if (char == 91 || char == 123) {
      closers.add(char == 91 ? 93 : 125);
    } else if (char == 93 || char == 125) {
      if (closers.isEmpty || closers.removeLast() != char) return null;
      if (closers.isEmpty) return html.substring(start, i + 1);
    }
  }
  return null;
}
