/// Entry point of the Store sample app.
library;

import 'package:flutter/material.dart';

import 'app.dart';
import 'app_state.dart';
import 'open_url_web.dart';

void main() {
  runApp(StoreApp(state: AppState(), openUrl: openInSameTab));
}
