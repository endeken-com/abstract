import React from 'react';
import { KeyboardAvoidingView, Platform, ScrollView, type ScrollViewProps } from 'react-native';

/** Keep focused fields and the actions after them inside the visible part of a form. */
export function KeyboardAwareScrollView(props: ScrollViewProps) {
  return <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
    <ScrollView keyboardShouldPersistTaps="handled" keyboardDismissMode="interactive" {...props} />
  </KeyboardAvoidingView>;
}
