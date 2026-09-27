// This is a generated file - do not edit.
//
// Generated from started_service.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use logLevelDescriptor instead')
const LogLevel$json = {
  '1': 'LogLevel',
  '2': [
    {'1': 'PANIC', '2': 0},
    {'1': 'FATAL', '2': 1},
    {'1': 'ERROR', '2': 2},
    {'1': 'WARN', '2': 3},
    {'1': 'INFO', '2': 4},
    {'1': 'DEBUG', '2': 5},
    {'1': 'TRACE', '2': 6},
  ],
};

/// Descriptor for `LogLevel`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List logLevelDescriptor = $convert.base64Decode(
    'CghMb2dMZXZlbBIJCgVQQU5JQxAAEgkKBUZBVEFMEAESCQoFRVJST1IQAhIICgRXQVJOEAMSCA'
    'oESU5GTxAEEgkKBURFQlVHEAUSCQoFVFJBQ0UQBg==');

@$core.Deprecated('Use connectionEventTypeDescriptor instead')
const ConnectionEventType$json = {
  '1': 'ConnectionEventType',
  '2': [
    {'1': 'CONNECTION_EVENT_NEW', '2': 0},
    {'1': 'CONNECTION_EVENT_UPDATE', '2': 1},
    {'1': 'CONNECTION_EVENT_CLOSED', '2': 2},
  ],
};

/// Descriptor for `ConnectionEventType`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List connectionEventTypeDescriptor = $convert.base64Decode(
    'ChNDb25uZWN0aW9uRXZlbnRUeXBlEhgKFENPTk5FQ1RJT05fRVZFTlRfTkVXEAASGwoXQ09OTk'
    'VDVElPTl9FVkVOVF9VUERBVEUQARIbChdDT05ORUNUSU9OX0VWRU5UX0NMT1NFRBAC');

@$core.Deprecated('Use uSBDeviceStateDescriptor instead')
const USBDeviceState$json = {
  '1': 'USBDeviceState',
  '2': [
    {'1': 'USB_DEVICE_STATE_IDLE', '2': 0},
    {'1': 'USB_DEVICE_STATE_ATTACHED', '2': 1},
    {'1': 'USB_DEVICE_STATE_UNAVAILABLE', '2': 2},
  ],
};

/// Descriptor for `USBDeviceState`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List uSBDeviceStateDescriptor = $convert.base64Decode(
    'Cg5VU0JEZXZpY2VTdGF0ZRIZChVVU0JfREVWSUNFX1NUQVRFX0lETEUQABIdChlVU0JfREVWSU'
    'NFX1NUQVRFX0FUVEFDSEVEEAESIAocVVNCX0RFVklDRV9TVEFURV9VTkFWQUlMQUJMRRAC');

@$core.Deprecated('Use uSBBackendDescriptor instead')
const USBBackend$json = {
  '1': 'USBBackend',
  '2': [
    {'1': 'USB_BACKEND_UNSPECIFIED', '2': 0},
    {'1': 'USB_BACKEND_LINUX_SYSFS', '2': 1},
    {'1': 'USB_BACKEND_DYNAMIC', '2': 2},
    {'1': 'USB_BACKEND_DARWIN_IOKIT', '2': 3},
    {'1': 'USB_BACKEND_WINDOWS_VBOXUSB', '2': 4},
  ],
};

/// Descriptor for `USBBackend`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List uSBBackendDescriptor = $convert.base64Decode(
    'CgpVU0JCYWNrZW5kEhsKF1VTQl9CQUNLRU5EX1VOU1BFQ0lGSUVEEAASGwoXVVNCX0JBQ0tFTk'
    'RfTElOVVhfU1lTRlMQARIXChNVU0JfQkFDS0VORF9EWU5BTUlDEAISHAoYVVNCX0JBQ0tFTkRf'
    'REFSV0lOX0lPS0lUEAMSHwobVVNCX0JBQ0tFTkRfV0lORE9XU19WQk9YVVNCEAQ=');

@$core.Deprecated('Use versionDescriptor instead')
const Version$json = {
  '1': 'Version',
  '2': [
    {'1': 'version', '3': 1, '4': 1, '5': 9, '10': 'version'},
    {'1': 'apiVersion', '3': 2, '4': 1, '5': 5, '10': 'apiVersion'},
  ],
};

/// Descriptor for `Version`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List versionDescriptor = $convert.base64Decode(
    'CgdWZXJzaW9uEhgKB3ZlcnNpb24YASABKAlSB3ZlcnNpb24SHgoKYXBpVmVyc2lvbhgCIAEoBV'
    'IKYXBpVmVyc2lvbg==');

@$core.Deprecated('Use serviceStatusDescriptor instead')
const ServiceStatus$json = {
  '1': 'ServiceStatus',
  '2': [
    {
      '1': 'status',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.daemon.ServiceStatus.Type',
      '10': 'status'
    },
    {'1': 'errorMessage', '3': 2, '4': 1, '5': 9, '10': 'errorMessage'},
  ],
  '4': [ServiceStatus_Type$json],
};

@$core.Deprecated('Use serviceStatusDescriptor instead')
const ServiceStatus_Type$json = {
  '1': 'Type',
  '2': [
    {'1': 'IDLE', '2': 0},
    {'1': 'STARTING', '2': 1},
    {'1': 'STARTED', '2': 2},
    {'1': 'STOPPING', '2': 3},
    {'1': 'FATAL', '2': 4},
  ],
};

/// Descriptor for `ServiceStatus`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List serviceStatusDescriptor = $convert.base64Decode(
    'Cg1TZXJ2aWNlU3RhdHVzEjIKBnN0YXR1cxgBIAEoDjIaLmRhZW1vbi5TZXJ2aWNlU3RhdHVzLl'
    'R5cGVSBnN0YXR1cxIiCgxlcnJvck1lc3NhZ2UYAiABKAlSDGVycm9yTWVzc2FnZSJECgRUeXBl'
    'EggKBElETEUQABIMCghTVEFSVElORxABEgsKB1NUQVJURUQQAhIMCghTVE9QUElORxADEgkKBU'
    'ZBVEFMEAQ=');

@$core.Deprecated('Use subscribeStatusRequestDescriptor instead')
const SubscribeStatusRequest$json = {
  '1': 'SubscribeStatusRequest',
  '2': [
    {'1': 'interval', '3': 1, '4': 1, '5': 3, '10': 'interval'},
  ],
};

/// Descriptor for `SubscribeStatusRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subscribeStatusRequestDescriptor =
    $convert.base64Decode(
        'ChZTdWJzY3JpYmVTdGF0dXNSZXF1ZXN0EhoKCGludGVydmFsGAEgASgDUghpbnRlcnZhbA==');

@$core.Deprecated('Use logDescriptor instead')
const Log$json = {
  '1': 'Log',
  '2': [
    {
      '1': 'messages',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.daemon.Log.Message',
      '10': 'messages'
    },
    {'1': 'reset', '3': 2, '4': 1, '5': 8, '10': 'reset'},
  ],
  '3': [Log_Message$json],
};

@$core.Deprecated('Use logDescriptor instead')
const Log_Message$json = {
  '1': 'Message',
  '2': [
    {
      '1': 'level',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.daemon.LogLevel',
      '10': 'level'
    },
    {'1': 'message', '3': 2, '4': 1, '5': 9, '10': 'message'},
  ],
};

/// Descriptor for `Log`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List logDescriptor = $convert.base64Decode(
    'CgNMb2cSLwoIbWVzc2FnZXMYASADKAsyEy5kYWVtb24uTG9nLk1lc3NhZ2VSCG1lc3NhZ2VzEh'
    'QKBXJlc2V0GAIgASgIUgVyZXNldBpLCgdNZXNzYWdlEiYKBWxldmVsGAEgASgOMhAuZGFlbW9u'
    'LkxvZ0xldmVsUgVsZXZlbBIYCgdtZXNzYWdlGAIgASgJUgdtZXNzYWdl');

@$core.Deprecated('Use defaultLogLevelDescriptor instead')
const DefaultLogLevel$json = {
  '1': 'DefaultLogLevel',
  '2': [
    {
      '1': 'level',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.daemon.LogLevel',
      '10': 'level'
    },
  ],
};

/// Descriptor for `DefaultLogLevel`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List defaultLogLevelDescriptor = $convert.base64Decode(
    'Cg9EZWZhdWx0TG9nTGV2ZWwSJgoFbGV2ZWwYASABKA4yEC5kYWVtb24uTG9nTGV2ZWxSBWxldm'
    'Vs');

@$core.Deprecated('Use statusDescriptor instead')
const Status$json = {
  '1': 'Status',
  '2': [
    {'1': 'memory', '3': 1, '4': 1, '5': 4, '10': 'memory'},
    {'1': 'goroutines', '3': 2, '4': 1, '5': 5, '10': 'goroutines'},
    {'1': 'connectionsIn', '3': 3, '4': 1, '5': 5, '10': 'connectionsIn'},
    {'1': 'connectionsOut', '3': 4, '4': 1, '5': 5, '10': 'connectionsOut'},
    {'1': 'trafficAvailable', '3': 5, '4': 1, '5': 8, '10': 'trafficAvailable'},
    {'1': 'uplink', '3': 6, '4': 1, '5': 3, '10': 'uplink'},
    {'1': 'downlink', '3': 7, '4': 1, '5': 3, '10': 'downlink'},
    {'1': 'uplinkTotal', '3': 8, '4': 1, '5': 3, '10': 'uplinkTotal'},
    {'1': 'downlinkTotal', '3': 9, '4': 1, '5': 3, '10': 'downlinkTotal'},
  ],
};

/// Descriptor for `Status`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List statusDescriptor = $convert.base64Decode(
    'CgZTdGF0dXMSFgoGbWVtb3J5GAEgASgEUgZtZW1vcnkSHgoKZ29yb3V0aW5lcxgCIAEoBVIKZ2'
    '9yb3V0aW5lcxIkCg1jb25uZWN0aW9uc0luGAMgASgFUg1jb25uZWN0aW9uc0luEiYKDmNvbm5l'
    'Y3Rpb25zT3V0GAQgASgFUg5jb25uZWN0aW9uc091dBIqChB0cmFmZmljQXZhaWxhYmxlGAUgAS'
    'gIUhB0cmFmZmljQXZhaWxhYmxlEhYKBnVwbGluaxgGIAEoA1IGdXBsaW5rEhoKCGRvd25saW5r'
    'GAcgASgDUghkb3dubGluaxIgCgt1cGxpbmtUb3RhbBgIIAEoA1ILdXBsaW5rVG90YWwSJAoNZG'
    '93bmxpbmtUb3RhbBgJIAEoA1INZG93bmxpbmtUb3RhbA==');

@$core.Deprecated('Use groupsDescriptor instead')
const Groups$json = {
  '1': 'Groups',
  '2': [
    {
      '1': 'group',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.daemon.Group',
      '10': 'group'
    },
  ],
};

/// Descriptor for `Groups`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List groupsDescriptor = $convert.base64Decode(
    'CgZHcm91cHMSIwoFZ3JvdXAYASADKAsyDS5kYWVtb24uR3JvdXBSBWdyb3Vw');

@$core.Deprecated('Use groupDescriptor instead')
const Group$json = {
  '1': 'Group',
  '2': [
    {'1': 'tag', '3': 1, '4': 1, '5': 9, '10': 'tag'},
    {'1': 'type', '3': 2, '4': 1, '5': 9, '10': 'type'},
    {'1': 'selectable', '3': 3, '4': 1, '5': 8, '10': 'selectable'},
    {'1': 'selected', '3': 4, '4': 1, '5': 9, '10': 'selected'},
    {'1': 'isExpand', '3': 5, '4': 1, '5': 8, '10': 'isExpand'},
    {
      '1': 'items',
      '3': 6,
      '4': 3,
      '5': 11,
      '6': '.daemon.GroupItem',
      '10': 'items'
    },
  ],
};

/// Descriptor for `Group`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List groupDescriptor = $convert.base64Decode(
    'CgVHcm91cBIQCgN0YWcYASABKAlSA3RhZxISCgR0eXBlGAIgASgJUgR0eXBlEh4KCnNlbGVjdG'
    'FibGUYAyABKAhSCnNlbGVjdGFibGUSGgoIc2VsZWN0ZWQYBCABKAlSCHNlbGVjdGVkEhoKCGlz'
    'RXhwYW5kGAUgASgIUghpc0V4cGFuZBInCgVpdGVtcxgGIAMoCzIRLmRhZW1vbi5Hcm91cEl0ZW'
    '1SBWl0ZW1z');

@$core.Deprecated('Use groupItemDescriptor instead')
const GroupItem$json = {
  '1': 'GroupItem',
  '2': [
    {'1': 'tag', '3': 1, '4': 1, '5': 9, '10': 'tag'},
    {'1': 'type', '3': 2, '4': 1, '5': 9, '10': 'type'},
    {'1': 'urlTestTime', '3': 3, '4': 1, '5': 3, '10': 'urlTestTime'},
    {'1': 'urlTestDelay', '3': 4, '4': 1, '5': 5, '10': 'urlTestDelay'},
  ],
};

/// Descriptor for `GroupItem`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List groupItemDescriptor = $convert.base64Decode(
    'CglHcm91cEl0ZW0SEAoDdGFnGAEgASgJUgN0YWcSEgoEdHlwZRgCIAEoCVIEdHlwZRIgCgt1cm'
    'xUZXN0VGltZRgDIAEoA1ILdXJsVGVzdFRpbWUSIgoMdXJsVGVzdERlbGF5GAQgASgFUgx1cmxU'
    'ZXN0RGVsYXk=');

@$core.Deprecated('Use uRLTestRequestDescriptor instead')
const URLTestRequest$json = {
  '1': 'URLTestRequest',
  '2': [
    {'1': 'outboundTag', '3': 1, '4': 1, '5': 9, '10': 'outboundTag'},
  ],
};

/// Descriptor for `URLTestRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uRLTestRequestDescriptor = $convert.base64Decode(
    'Cg5VUkxUZXN0UmVxdWVzdBIgCgtvdXRib3VuZFRhZxgBIAEoCVILb3V0Ym91bmRUYWc=');

@$core.Deprecated('Use selectOutboundRequestDescriptor instead')
const SelectOutboundRequest$json = {
  '1': 'SelectOutboundRequest',
  '2': [
    {'1': 'groupTag', '3': 1, '4': 1, '5': 9, '10': 'groupTag'},
    {'1': 'outboundTag', '3': 2, '4': 1, '5': 9, '10': 'outboundTag'},
  ],
};

/// Descriptor for `SelectOutboundRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List selectOutboundRequestDescriptor = $convert.base64Decode(
    'ChVTZWxlY3RPdXRib3VuZFJlcXVlc3QSGgoIZ3JvdXBUYWcYASABKAlSCGdyb3VwVGFnEiAKC2'
    '91dGJvdW5kVGFnGAIgASgJUgtvdXRib3VuZFRhZw==');

@$core.Deprecated('Use setGroupExpandRequestDescriptor instead')
const SetGroupExpandRequest$json = {
  '1': 'SetGroupExpandRequest',
  '2': [
    {'1': 'groupTag', '3': 1, '4': 1, '5': 9, '10': 'groupTag'},
    {'1': 'isExpand', '3': 2, '4': 1, '5': 8, '10': 'isExpand'},
  ],
};

/// Descriptor for `SetGroupExpandRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List setGroupExpandRequestDescriptor = $convert.base64Decode(
    'ChVTZXRHcm91cEV4cGFuZFJlcXVlc3QSGgoIZ3JvdXBUYWcYASABKAlSCGdyb3VwVGFnEhoKCG'
    'lzRXhwYW5kGAIgASgIUghpc0V4cGFuZA==');

@$core.Deprecated('Use clashModeDescriptor instead')
const ClashMode$json = {
  '1': 'ClashMode',
  '2': [
    {'1': 'mode', '3': 3, '4': 1, '5': 9, '10': 'mode'},
  ],
};

/// Descriptor for `ClashMode`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clashModeDescriptor =
    $convert.base64Decode('CglDbGFzaE1vZGUSEgoEbW9kZRgDIAEoCVIEbW9kZQ==');

@$core.Deprecated('Use clashModeStatusDescriptor instead')
const ClashModeStatus$json = {
  '1': 'ClashModeStatus',
  '2': [
    {'1': 'modeList', '3': 1, '4': 3, '5': 9, '10': 'modeList'},
    {'1': 'currentMode', '3': 2, '4': 1, '5': 9, '10': 'currentMode'},
  ],
};

/// Descriptor for `ClashModeStatus`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clashModeStatusDescriptor = $convert.base64Decode(
    'Cg9DbGFzaE1vZGVTdGF0dXMSGgoIbW9kZUxpc3QYASADKAlSCG1vZGVMaXN0EiAKC2N1cnJlbn'
    'RNb2RlGAIgASgJUgtjdXJyZW50TW9kZQ==');

@$core.Deprecated('Use subscribeConnectionsRequestDescriptor instead')
const SubscribeConnectionsRequest$json = {
  '1': 'SubscribeConnectionsRequest',
  '2': [
    {'1': 'interval', '3': 1, '4': 1, '5': 3, '10': 'interval'},
  ],
};

/// Descriptor for `SubscribeConnectionsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subscribeConnectionsRequestDescriptor =
    $convert.base64Decode(
        'ChtTdWJzY3JpYmVDb25uZWN0aW9uc1JlcXVlc3QSGgoIaW50ZXJ2YWwYASABKANSCGludGVydm'
        'Fs');

@$core.Deprecated('Use connectionEventDescriptor instead')
const ConnectionEvent$json = {
  '1': 'ConnectionEvent',
  '2': [
    {
      '1': 'type',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.daemon.ConnectionEventType',
      '10': 'type'
    },
    {'1': 'id', '3': 2, '4': 1, '5': 9, '10': 'id'},
    {
      '1': 'connection',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.daemon.Connection',
      '10': 'connection'
    },
    {'1': 'uplinkDelta', '3': 4, '4': 1, '5': 3, '10': 'uplinkDelta'},
    {'1': 'downlinkDelta', '3': 5, '4': 1, '5': 3, '10': 'downlinkDelta'},
    {'1': 'closedAt', '3': 6, '4': 1, '5': 3, '10': 'closedAt'},
  ],
};

/// Descriptor for `ConnectionEvent`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List connectionEventDescriptor = $convert.base64Decode(
    'Cg9Db25uZWN0aW9uRXZlbnQSLwoEdHlwZRgBIAEoDjIbLmRhZW1vbi5Db25uZWN0aW9uRXZlbn'
    'RUeXBlUgR0eXBlEg4KAmlkGAIgASgJUgJpZBIyCgpjb25uZWN0aW9uGAMgASgLMhIuZGFlbW9u'
    'LkNvbm5lY3Rpb25SCmNvbm5lY3Rpb24SIAoLdXBsaW5rRGVsdGEYBCABKANSC3VwbGlua0RlbH'
    'RhEiQKDWRvd25saW5rRGVsdGEYBSABKANSDWRvd25saW5rRGVsdGESGgoIY2xvc2VkQXQYBiAB'
    'KANSCGNsb3NlZEF0');

@$core.Deprecated('Use connectionEventsDescriptor instead')
const ConnectionEvents$json = {
  '1': 'ConnectionEvents',
  '2': [
    {
      '1': 'events',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.daemon.ConnectionEvent',
      '10': 'events'
    },
    {'1': 'reset', '3': 2, '4': 1, '5': 8, '10': 'reset'},
  ],
};

/// Descriptor for `ConnectionEvents`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List connectionEventsDescriptor = $convert.base64Decode(
    'ChBDb25uZWN0aW9uRXZlbnRzEi8KBmV2ZW50cxgBIAMoCzIXLmRhZW1vbi5Db25uZWN0aW9uRX'
    'ZlbnRSBmV2ZW50cxIUCgVyZXNldBgCIAEoCFIFcmVzZXQ=');

@$core.Deprecated('Use connectionDescriptor instead')
const Connection$json = {
  '1': 'Connection',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'inbound', '3': 2, '4': 1, '5': 9, '10': 'inbound'},
    {'1': 'inboundType', '3': 3, '4': 1, '5': 9, '10': 'inboundType'},
    {'1': 'ipVersion', '3': 4, '4': 1, '5': 5, '10': 'ipVersion'},
    {'1': 'network', '3': 5, '4': 1, '5': 9, '10': 'network'},
    {'1': 'source', '3': 6, '4': 1, '5': 9, '10': 'source'},
    {'1': 'destination', '3': 7, '4': 1, '5': 9, '10': 'destination'},
    {'1': 'domain', '3': 8, '4': 1, '5': 9, '10': 'domain'},
    {'1': 'protocol', '3': 9, '4': 1, '5': 9, '10': 'protocol'},
    {'1': 'user', '3': 10, '4': 1, '5': 9, '10': 'user'},
    {'1': 'fromOutbound', '3': 11, '4': 1, '5': 9, '10': 'fromOutbound'},
    {'1': 'createdAt', '3': 12, '4': 1, '5': 3, '10': 'createdAt'},
    {'1': 'closedAt', '3': 13, '4': 1, '5': 3, '10': 'closedAt'},
    {'1': 'uplink', '3': 14, '4': 1, '5': 3, '10': 'uplink'},
    {'1': 'downlink', '3': 15, '4': 1, '5': 3, '10': 'downlink'},
    {'1': 'uplinkTotal', '3': 16, '4': 1, '5': 3, '10': 'uplinkTotal'},
    {'1': 'downlinkTotal', '3': 17, '4': 1, '5': 3, '10': 'downlinkTotal'},
    {'1': 'rule', '3': 18, '4': 1, '5': 9, '10': 'rule'},
    {'1': 'outbound', '3': 19, '4': 1, '5': 9, '10': 'outbound'},
    {'1': 'outboundType', '3': 20, '4': 1, '5': 9, '10': 'outboundType'},
    {'1': 'chainList', '3': 21, '4': 3, '5': 9, '10': 'chainList'},
    {
      '1': 'processInfo',
      '3': 22,
      '4': 1,
      '5': 11,
      '6': '.daemon.ProcessInfo',
      '10': 'processInfo'
    },
  ],
};

/// Descriptor for `Connection`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List connectionDescriptor = $convert.base64Decode(
    'CgpDb25uZWN0aW9uEg4KAmlkGAEgASgJUgJpZBIYCgdpbmJvdW5kGAIgASgJUgdpbmJvdW5kEi'
    'AKC2luYm91bmRUeXBlGAMgASgJUgtpbmJvdW5kVHlwZRIcCglpcFZlcnNpb24YBCABKAVSCWlw'
    'VmVyc2lvbhIYCgduZXR3b3JrGAUgASgJUgduZXR3b3JrEhYKBnNvdXJjZRgGIAEoCVIGc291cm'
    'NlEiAKC2Rlc3RpbmF0aW9uGAcgASgJUgtkZXN0aW5hdGlvbhIWCgZkb21haW4YCCABKAlSBmRv'
    'bWFpbhIaCghwcm90b2NvbBgJIAEoCVIIcHJvdG9jb2wSEgoEdXNlchgKIAEoCVIEdXNlchIiCg'
    'xmcm9tT3V0Ym91bmQYCyABKAlSDGZyb21PdXRib3VuZBIcCgljcmVhdGVkQXQYDCABKANSCWNy'
    'ZWF0ZWRBdBIaCghjbG9zZWRBdBgNIAEoA1IIY2xvc2VkQXQSFgoGdXBsaW5rGA4gASgDUgZ1cG'
    'xpbmsSGgoIZG93bmxpbmsYDyABKANSCGRvd25saW5rEiAKC3VwbGlua1RvdGFsGBAgASgDUgt1'
    'cGxpbmtUb3RhbBIkCg1kb3dubGlua1RvdGFsGBEgASgDUg1kb3dubGlua1RvdGFsEhIKBHJ1bG'
    'UYEiABKAlSBHJ1bGUSGgoIb3V0Ym91bmQYEyABKAlSCG91dGJvdW5kEiIKDG91dGJvdW5kVHlw'
    'ZRgUIAEoCVIMb3V0Ym91bmRUeXBlEhwKCWNoYWluTGlzdBgVIAMoCVIJY2hhaW5MaXN0EjUKC3'
    'Byb2Nlc3NJbmZvGBYgASgLMhMuZGFlbW9uLlByb2Nlc3NJbmZvUgtwcm9jZXNzSW5mbw==');

@$core.Deprecated('Use processInfoDescriptor instead')
const ProcessInfo$json = {
  '1': 'ProcessInfo',
  '2': [
    {'1': 'processId', '3': 1, '4': 1, '5': 13, '10': 'processId'},
    {'1': 'userId', '3': 2, '4': 1, '5': 5, '10': 'userId'},
    {'1': 'userName', '3': 3, '4': 1, '5': 9, '10': 'userName'},
    {'1': 'processPath', '3': 4, '4': 1, '5': 9, '10': 'processPath'},
    {'1': 'packageNames', '3': 5, '4': 3, '5': 9, '10': 'packageNames'},
  ],
};

/// Descriptor for `ProcessInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List processInfoDescriptor = $convert.base64Decode(
    'CgtQcm9jZXNzSW5mbxIcCglwcm9jZXNzSWQYASABKA1SCXByb2Nlc3NJZBIWCgZ1c2VySWQYAi'
    'ABKAVSBnVzZXJJZBIaCgh1c2VyTmFtZRgDIAEoCVIIdXNlck5hbWUSIAoLcHJvY2Vzc1BhdGgY'
    'BCABKAlSC3Byb2Nlc3NQYXRoEiIKDHBhY2thZ2VOYW1lcxgFIAMoCVIMcGFja2FnZU5hbWVz');

@$core.Deprecated('Use closeConnectionRequestDescriptor instead')
const CloseConnectionRequest$json = {
  '1': 'CloseConnectionRequest',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
  ],
};

/// Descriptor for `CloseConnectionRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List closeConnectionRequestDescriptor = $convert
    .base64Decode('ChZDbG9zZUNvbm5lY3Rpb25SZXF1ZXN0Eg4KAmlkGAEgASgJUgJpZA==');

@$core.Deprecated('Use deprecatedWarningsDescriptor instead')
const DeprecatedWarnings$json = {
  '1': 'DeprecatedWarnings',
  '2': [
    {
      '1': 'warnings',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.daemon.DeprecatedWarning',
      '10': 'warnings'
    },
  ],
};

/// Descriptor for `DeprecatedWarnings`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deprecatedWarningsDescriptor = $convert.base64Decode(
    'ChJEZXByZWNhdGVkV2FybmluZ3MSNQoId2FybmluZ3MYASADKAsyGS5kYWVtb24uRGVwcmVjYX'
    'RlZFdhcm5pbmdSCHdhcm5pbmdz');

@$core.Deprecated('Use deprecatedWarningDescriptor instead')
const DeprecatedWarning$json = {
  '1': 'DeprecatedWarning',
  '2': [
    {'1': 'message', '3': 1, '4': 1, '5': 9, '10': 'message'},
    {'1': 'impending', '3': 2, '4': 1, '5': 8, '10': 'impending'},
    {'1': 'migrationLink', '3': 3, '4': 1, '5': 9, '10': 'migrationLink'},
    {'1': 'description', '3': 4, '4': 1, '5': 9, '10': 'description'},
    {
      '1': 'deprecatedVersion',
      '3': 5,
      '4': 1,
      '5': 9,
      '10': 'deprecatedVersion'
    },
    {'1': 'scheduledVersion', '3': 6, '4': 1, '5': 9, '10': 'scheduledVersion'},
  ],
};

/// Descriptor for `DeprecatedWarning`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deprecatedWarningDescriptor = $convert.base64Decode(
    'ChFEZXByZWNhdGVkV2FybmluZxIYCgdtZXNzYWdlGAEgASgJUgdtZXNzYWdlEhwKCWltcGVuZG'
    'luZxgCIAEoCFIJaW1wZW5kaW5nEiQKDW1pZ3JhdGlvbkxpbmsYAyABKAlSDW1pZ3JhdGlvbkxp'
    'bmsSIAoLZGVzY3JpcHRpb24YBCABKAlSC2Rlc2NyaXB0aW9uEiwKEWRlcHJlY2F0ZWRWZXJzaW'
    '9uGAUgASgJUhFkZXByZWNhdGVkVmVyc2lvbhIqChBzY2hlZHVsZWRWZXJzaW9uGAYgASgJUhBz'
    'Y2hlZHVsZWRWZXJzaW9u');

@$core.Deprecated('Use startedAtDescriptor instead')
const StartedAt$json = {
  '1': 'StartedAt',
  '2': [
    {'1': 'startedAt', '3': 1, '4': 1, '5': 3, '10': 'startedAt'},
  ],
};

/// Descriptor for `StartedAt`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List startedAtDescriptor = $convert
    .base64Decode('CglTdGFydGVkQXQSHAoJc3RhcnRlZEF0GAEgASgDUglzdGFydGVkQXQ=');

@$core.Deprecated('Use outboundListDescriptor instead')
const OutboundList$json = {
  '1': 'OutboundList',
  '2': [
    {
      '1': 'outbounds',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.daemon.GroupItem',
      '10': 'outbounds'
    },
  ],
};

/// Descriptor for `OutboundList`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List outboundListDescriptor = $convert.base64Decode(
    'CgxPdXRib3VuZExpc3QSLwoJb3V0Ym91bmRzGAEgAygLMhEuZGFlbW9uLkdyb3VwSXRlbVIJb3'
    'V0Ym91bmRz');

@$core.Deprecated('Use networkQualityTestRequestDescriptor instead')
const NetworkQualityTestRequest$json = {
  '1': 'NetworkQualityTestRequest',
  '2': [
    {'1': 'configURL', '3': 1, '4': 1, '5': 9, '10': 'configURL'},
    {'1': 'outboundTag', '3': 2, '4': 1, '5': 9, '10': 'outboundTag'},
    {'1': 'serial', '3': 3, '4': 1, '5': 8, '10': 'serial'},
    {
      '1': 'maxRuntimeSeconds',
      '3': 4,
      '4': 1,
      '5': 5,
      '10': 'maxRuntimeSeconds'
    },
    {'1': 'http3', '3': 5, '4': 1, '5': 8, '10': 'http3'},
  ],
};

/// Descriptor for `NetworkQualityTestRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List networkQualityTestRequestDescriptor = $convert.base64Decode(
    'ChlOZXR3b3JrUXVhbGl0eVRlc3RSZXF1ZXN0EhwKCWNvbmZpZ1VSTBgBIAEoCVIJY29uZmlnVV'
    'JMEiAKC291dGJvdW5kVGFnGAIgASgJUgtvdXRib3VuZFRhZxIWCgZzZXJpYWwYAyABKAhSBnNl'
    'cmlhbBIsChFtYXhSdW50aW1lU2Vjb25kcxgEIAEoBVIRbWF4UnVudGltZVNlY29uZHMSFAoFaH'
    'R0cDMYBSABKAhSBWh0dHAz');

@$core.Deprecated('Use networkQualityTestProgressDescriptor instead')
const NetworkQualityTestProgress$json = {
  '1': 'NetworkQualityTestProgress',
  '2': [
    {'1': 'phase', '3': 1, '4': 1, '5': 5, '10': 'phase'},
    {'1': 'downloadCapacity', '3': 2, '4': 1, '5': 3, '10': 'downloadCapacity'},
    {'1': 'uploadCapacity', '3': 3, '4': 1, '5': 3, '10': 'uploadCapacity'},
    {'1': 'downloadRPM', '3': 4, '4': 1, '5': 5, '10': 'downloadRPM'},
    {'1': 'uploadRPM', '3': 5, '4': 1, '5': 5, '10': 'uploadRPM'},
    {'1': 'idleLatencyMs', '3': 6, '4': 1, '5': 5, '10': 'idleLatencyMs'},
    {'1': 'elapsedMs', '3': 7, '4': 1, '5': 3, '10': 'elapsedMs'},
    {'1': 'isFinal', '3': 8, '4': 1, '5': 8, '10': 'isFinal'},
    {'1': 'error', '3': 9, '4': 1, '5': 9, '10': 'error'},
    {
      '1': 'downloadCapacityAccuracy',
      '3': 10,
      '4': 1,
      '5': 5,
      '10': 'downloadCapacityAccuracy'
    },
    {
      '1': 'uploadCapacityAccuracy',
      '3': 11,
      '4': 1,
      '5': 5,
      '10': 'uploadCapacityAccuracy'
    },
    {
      '1': 'downloadRPMAccuracy',
      '3': 12,
      '4': 1,
      '5': 5,
      '10': 'downloadRPMAccuracy'
    },
    {
      '1': 'uploadRPMAccuracy',
      '3': 13,
      '4': 1,
      '5': 5,
      '10': 'uploadRPMAccuracy'
    },
  ],
};

/// Descriptor for `NetworkQualityTestProgress`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List networkQualityTestProgressDescriptor = $convert.base64Decode(
    'ChpOZXR3b3JrUXVhbGl0eVRlc3RQcm9ncmVzcxIUCgVwaGFzZRgBIAEoBVIFcGhhc2USKgoQZG'
    '93bmxvYWRDYXBhY2l0eRgCIAEoA1IQZG93bmxvYWRDYXBhY2l0eRImCg51cGxvYWRDYXBhY2l0'
    'eRgDIAEoA1IOdXBsb2FkQ2FwYWNpdHkSIAoLZG93bmxvYWRSUE0YBCABKAVSC2Rvd25sb2FkUl'
    'BNEhwKCXVwbG9hZFJQTRgFIAEoBVIJdXBsb2FkUlBNEiQKDWlkbGVMYXRlbmN5TXMYBiABKAVS'
    'DWlkbGVMYXRlbmN5TXMSHAoJZWxhcHNlZE1zGAcgASgDUgllbGFwc2VkTXMSGAoHaXNGaW5hbB'
    'gIIAEoCFIHaXNGaW5hbBIUCgVlcnJvchgJIAEoCVIFZXJyb3ISOgoYZG93bmxvYWRDYXBhY2l0'
    'eUFjY3VyYWN5GAogASgFUhhkb3dubG9hZENhcGFjaXR5QWNjdXJhY3kSNgoWdXBsb2FkQ2FwYW'
    'NpdHlBY2N1cmFjeRgLIAEoBVIWdXBsb2FkQ2FwYWNpdHlBY2N1cmFjeRIwChNkb3dubG9hZFJQ'
    'TUFjY3VyYWN5GAwgASgFUhNkb3dubG9hZFJQTUFjY3VyYWN5EiwKEXVwbG9hZFJQTUFjY3VyYW'
    'N5GA0gASgFUhF1cGxvYWRSUE1BY2N1cmFjeQ==');

@$core.Deprecated('Use sTUNTestRequestDescriptor instead')
const STUNTestRequest$json = {
  '1': 'STUNTestRequest',
  '2': [
    {'1': 'server', '3': 1, '4': 1, '5': 9, '10': 'server'},
    {'1': 'outboundTag', '3': 2, '4': 1, '5': 9, '10': 'outboundTag'},
  ],
};

/// Descriptor for `STUNTestRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sTUNTestRequestDescriptor = $convert.base64Decode(
    'Cg9TVFVOVGVzdFJlcXVlc3QSFgoGc2VydmVyGAEgASgJUgZzZXJ2ZXISIAoLb3V0Ym91bmRUYW'
    'cYAiABKAlSC291dGJvdW5kVGFn');

@$core.Deprecated('Use sTUNTestProgressDescriptor instead')
const STUNTestProgress$json = {
  '1': 'STUNTestProgress',
  '2': [
    {'1': 'phase', '3': 1, '4': 1, '5': 5, '10': 'phase'},
    {'1': 'externalAddr', '3': 2, '4': 1, '5': 9, '10': 'externalAddr'},
    {'1': 'latencyMs', '3': 3, '4': 1, '5': 5, '10': 'latencyMs'},
    {'1': 'natMapping', '3': 4, '4': 1, '5': 5, '10': 'natMapping'},
    {'1': 'natFiltering', '3': 5, '4': 1, '5': 5, '10': 'natFiltering'},
    {'1': 'isFinal', '3': 6, '4': 1, '5': 8, '10': 'isFinal'},
    {'1': 'error', '3': 7, '4': 1, '5': 9, '10': 'error'},
    {'1': 'natTypeSupported', '3': 8, '4': 1, '5': 8, '10': 'natTypeSupported'},
  ],
};

/// Descriptor for `STUNTestProgress`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sTUNTestProgressDescriptor = $convert.base64Decode(
    'ChBTVFVOVGVzdFByb2dyZXNzEhQKBXBoYXNlGAEgASgFUgVwaGFzZRIiCgxleHRlcm5hbEFkZH'
    'IYAiABKAlSDGV4dGVybmFsQWRkchIcCglsYXRlbmN5TXMYAyABKAVSCWxhdGVuY3lNcxIeCgpu'
    'YXRNYXBwaW5nGAQgASgFUgpuYXRNYXBwaW5nEiIKDG5hdEZpbHRlcmluZxgFIAEoBVIMbmF0Rm'
    'lsdGVyaW5nEhgKB2lzRmluYWwYBiABKAhSB2lzRmluYWwSFAoFZXJyb3IYByABKAlSBWVycm9y'
    'EioKEG5hdFR5cGVTdXBwb3J0ZWQYCCABKAhSEG5hdFR5cGVTdXBwb3J0ZWQ=');

@$core.Deprecated('Use tailscaleStatusUpdateDescriptor instead')
const TailscaleStatusUpdate$json = {
  '1': 'TailscaleStatusUpdate',
  '2': [
    {
      '1': 'endpoints',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.daemon.TailscaleEndpointStatus',
      '10': 'endpoints'
    },
  ],
};

/// Descriptor for `TailscaleStatusUpdate`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleStatusUpdateDescriptor = $convert.base64Decode(
    'ChVUYWlsc2NhbGVTdGF0dXNVcGRhdGUSPQoJZW5kcG9pbnRzGAEgAygLMh8uZGFlbW9uLlRhaW'
    'xzY2FsZUVuZHBvaW50U3RhdHVzUgllbmRwb2ludHM=');

@$core.Deprecated('Use tailscaleEndpointStatusDescriptor instead')
const TailscaleEndpointStatus$json = {
  '1': 'TailscaleEndpointStatus',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'backendState', '3': 2, '4': 1, '5': 9, '10': 'backendState'},
    {'1': 'stateText', '3': 3, '4': 1, '5': 9, '10': 'stateText'},
    {'1': 'authURL', '3': 4, '4': 1, '5': 9, '10': 'authURL'},
    {'1': 'networkName', '3': 5, '4': 1, '5': 9, '10': 'networkName'},
    {'1': 'magicDNSSuffix', '3': 6, '4': 1, '5': 9, '10': 'magicDNSSuffix'},
    {
      '1': 'self',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.daemon.TailscalePeer',
      '10': 'self'
    },
    {
      '1': 'userGroups',
      '3': 8,
      '4': 3,
      '5': 11,
      '6': '.daemon.TailscaleUserGroup',
      '10': 'userGroups'
    },
    {
      '1': 'exitNode',
      '3': 9,
      '4': 1,
      '5': 11,
      '6': '.daemon.TailscalePeer',
      '10': 'exitNode'
    },
    {'1': 'keyAuth', '3': 10, '4': 1, '5': 8, '10': 'keyAuth'},
    {'1': 'canShareFiles', '3': 11, '4': 1, '5': 8, '10': 'canShareFiles'},
    {
      '1': 'waitingFileCount',
      '3': 12,
      '4': 1,
      '5': 5,
      '10': 'waitingFileCount'
    },
    {
      '1': 'receivingFileCount',
      '3': 13,
      '4': 1,
      '5': 5,
      '10': 'receivingFileCount'
    },
    {'1': 'unreadFileCount', '3': 14, '4': 1, '5': 5, '10': 'unreadFileCount'},
    {'1': 'certDomains', '3': 15, '4': 3, '5': 9, '10': 'certDomains'},
  ],
};

/// Descriptor for `TailscaleEndpointStatus`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleEndpointStatusDescriptor = $convert.base64Decode(
    'ChdUYWlsc2NhbGVFbmRwb2ludFN0YXR1cxIgCgtlbmRwb2ludFRhZxgBIAEoCVILZW5kcG9pbn'
    'RUYWcSIgoMYmFja2VuZFN0YXRlGAIgASgJUgxiYWNrZW5kU3RhdGUSHAoJc3RhdGVUZXh0GAMg'
    'ASgJUglzdGF0ZVRleHQSGAoHYXV0aFVSTBgEIAEoCVIHYXV0aFVSTBIgCgtuZXR3b3JrTmFtZR'
    'gFIAEoCVILbmV0d29ya05hbWUSJgoObWFnaWNETlNTdWZmaXgYBiABKAlSDm1hZ2ljRE5TU3Vm'
    'Zml4EikKBHNlbGYYByABKAsyFS5kYWVtb24uVGFpbHNjYWxlUGVlclIEc2VsZhI6Cgp1c2VyR3'
    'JvdXBzGAggAygLMhouZGFlbW9uLlRhaWxzY2FsZVVzZXJHcm91cFIKdXNlckdyb3VwcxIxCghl'
    'eGl0Tm9kZRgJIAEoCzIVLmRhZW1vbi5UYWlsc2NhbGVQZWVyUghleGl0Tm9kZRIYCgdrZXlBdX'
    'RoGAogASgIUgdrZXlBdXRoEiQKDWNhblNoYXJlRmlsZXMYCyABKAhSDWNhblNoYXJlRmlsZXMS'
    'KgoQd2FpdGluZ0ZpbGVDb3VudBgMIAEoBVIQd2FpdGluZ0ZpbGVDb3VudBIuChJyZWNlaXZpbm'
    'dGaWxlQ291bnQYDSABKAVSEnJlY2VpdmluZ0ZpbGVDb3VudBIoCg91bnJlYWRGaWxlQ291bnQY'
    'DiABKAVSD3VucmVhZEZpbGVDb3VudBIgCgtjZXJ0RG9tYWlucxgPIAMoCVILY2VydERvbWFpbn'
    'M=');

@$core.Deprecated('Use tailscaleUserGroupDescriptor instead')
const TailscaleUserGroup$json = {
  '1': 'TailscaleUserGroup',
  '2': [
    {'1': 'userID', '3': 1, '4': 1, '5': 3, '10': 'userID'},
    {'1': 'loginName', '3': 2, '4': 1, '5': 9, '10': 'loginName'},
    {'1': 'displayName', '3': 3, '4': 1, '5': 9, '10': 'displayName'},
    {'1': 'profilePicURL', '3': 4, '4': 1, '5': 9, '10': 'profilePicURL'},
    {
      '1': 'peers',
      '3': 5,
      '4': 3,
      '5': 11,
      '6': '.daemon.TailscalePeer',
      '10': 'peers'
    },
  ],
};

/// Descriptor for `TailscaleUserGroup`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleUserGroupDescriptor = $convert.base64Decode(
    'ChJUYWlsc2NhbGVVc2VyR3JvdXASFgoGdXNlcklEGAEgASgDUgZ1c2VySUQSHAoJbG9naW5OYW'
    '1lGAIgASgJUglsb2dpbk5hbWUSIAoLZGlzcGxheU5hbWUYAyABKAlSC2Rpc3BsYXlOYW1lEiQK'
    'DXByb2ZpbGVQaWNVUkwYBCABKAlSDXByb2ZpbGVQaWNVUkwSKwoFcGVlcnMYBSADKAsyFS5kYW'
    'Vtb24uVGFpbHNjYWxlUGVlclIFcGVlcnM=');

@$core.Deprecated('Use tailscalePeerDescriptor instead')
const TailscalePeer$json = {
  '1': 'TailscalePeer',
  '2': [
    {'1': 'hostName', '3': 1, '4': 1, '5': 9, '10': 'hostName'},
    {'1': 'dnsName', '3': 2, '4': 1, '5': 9, '10': 'dnsName'},
    {'1': 'os', '3': 3, '4': 1, '5': 9, '10': 'os'},
    {'1': 'tailscaleIPs', '3': 4, '4': 3, '5': 9, '10': 'tailscaleIPs'},
    {'1': 'online', '3': 5, '4': 1, '5': 8, '10': 'online'},
    {'1': 'exitNode', '3': 6, '4': 1, '5': 8, '10': 'exitNode'},
    {'1': 'exitNodeOption', '3': 7, '4': 1, '5': 8, '10': 'exitNodeOption'},
    {'1': 'active', '3': 8, '4': 1, '5': 8, '10': 'active'},
    {'1': 'rxBytes', '3': 9, '4': 1, '5': 3, '10': 'rxBytes'},
    {'1': 'txBytes', '3': 10, '4': 1, '5': 3, '10': 'txBytes'},
    {'1': 'keyExpiry', '3': 11, '4': 1, '5': 3, '10': 'keyExpiry'},
    {'1': 'stableID', '3': 12, '4': 1, '5': 9, '10': 'stableID'},
    {'1': 'expired', '3': 13, '4': 1, '5': 8, '10': 'expired'},
    {'1': 'sshHostKeys', '3': 14, '4': 3, '5': 9, '10': 'sshHostKeys'},
    {'1': 'shareeNode', '3': 15, '4': 1, '5': 8, '10': 'shareeNode'},
    {'1': 'lastSeen', '3': 16, '4': 1, '5': 3, '10': 'lastSeen'},
    {'1': 'canReceiveFiles', '3': 17, '4': 1, '5': 8, '10': 'canReceiveFiles'},
  ],
};

/// Descriptor for `TailscalePeer`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscalePeerDescriptor = $convert.base64Decode(
    'Cg1UYWlsc2NhbGVQZWVyEhoKCGhvc3ROYW1lGAEgASgJUghob3N0TmFtZRIYCgdkbnNOYW1lGA'
    'IgASgJUgdkbnNOYW1lEg4KAm9zGAMgASgJUgJvcxIiCgx0YWlsc2NhbGVJUHMYBCADKAlSDHRh'
    'aWxzY2FsZUlQcxIWCgZvbmxpbmUYBSABKAhSBm9ubGluZRIaCghleGl0Tm9kZRgGIAEoCFIIZX'
    'hpdE5vZGUSJgoOZXhpdE5vZGVPcHRpb24YByABKAhSDmV4aXROb2RlT3B0aW9uEhYKBmFjdGl2'
    'ZRgIIAEoCFIGYWN0aXZlEhgKB3J4Qnl0ZXMYCSABKANSB3J4Qnl0ZXMSGAoHdHhCeXRlcxgKIA'
    'EoA1IHdHhCeXRlcxIcCglrZXlFeHBpcnkYCyABKANSCWtleUV4cGlyeRIaCghzdGFibGVJRBgM'
    'IAEoCVIIc3RhYmxlSUQSGAoHZXhwaXJlZBgNIAEoCFIHZXhwaXJlZBIgCgtzc2hIb3N0S2V5cx'
    'gOIAMoCVILc3NoSG9zdEtleXMSHgoKc2hhcmVlTm9kZRgPIAEoCFIKc2hhcmVlTm9kZRIaCghs'
    'YXN0U2VlbhgQIAEoA1IIbGFzdFNlZW4SKAoPY2FuUmVjZWl2ZUZpbGVzGBEgASgIUg9jYW5SZW'
    'NlaXZlRmlsZXM=');

@$core.Deprecated('Use tailscalePingRequestDescriptor instead')
const TailscalePingRequest$json = {
  '1': 'TailscalePingRequest',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'peerIP', '3': 2, '4': 1, '5': 9, '10': 'peerIP'},
  ],
};

/// Descriptor for `TailscalePingRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscalePingRequestDescriptor = $convert.base64Decode(
    'ChRUYWlsc2NhbGVQaW5nUmVxdWVzdBIgCgtlbmRwb2ludFRhZxgBIAEoCVILZW5kcG9pbnRUYW'
    'cSFgoGcGVlcklQGAIgASgJUgZwZWVySVA=');

@$core.Deprecated('Use tailscalePingResponseDescriptor instead')
const TailscalePingResponse$json = {
  '1': 'TailscalePingResponse',
  '2': [
    {'1': 'latencyMs', '3': 1, '4': 1, '5': 1, '10': 'latencyMs'},
    {'1': 'isDirect', '3': 2, '4': 1, '5': 8, '10': 'isDirect'},
    {'1': 'endpoint', '3': 3, '4': 1, '5': 9, '10': 'endpoint'},
    {'1': 'derpRegionID', '3': 4, '4': 1, '5': 5, '10': 'derpRegionID'},
    {'1': 'derpRegionCode', '3': 5, '4': 1, '5': 9, '10': 'derpRegionCode'},
    {'1': 'error', '3': 6, '4': 1, '5': 9, '10': 'error'},
    {'1': 'peerRelay', '3': 7, '4': 1, '5': 9, '10': 'peerRelay'},
  ],
};

/// Descriptor for `TailscalePingResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscalePingResponseDescriptor = $convert.base64Decode(
    'ChVUYWlsc2NhbGVQaW5nUmVzcG9uc2USHAoJbGF0ZW5jeU1zGAEgASgBUglsYXRlbmN5TXMSGg'
    'oIaXNEaXJlY3QYAiABKAhSCGlzRGlyZWN0EhoKCGVuZHBvaW50GAMgASgJUghlbmRwb2ludBIi'
    'CgxkZXJwUmVnaW9uSUQYBCABKAVSDGRlcnBSZWdpb25JRBImCg5kZXJwUmVnaW9uQ29kZRgFIA'
    'EoCVIOZGVycFJlZ2lvbkNvZGUSFAoFZXJyb3IYBiABKAlSBWVycm9yEhwKCXBlZXJSZWxheRgH'
    'IAEoCVIJcGVlclJlbGF5');

@$core.Deprecated('Use setTailscaleExitNodeRequestDescriptor instead')
const SetTailscaleExitNodeRequest$json = {
  '1': 'SetTailscaleExitNodeRequest',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'stableID', '3': 2, '4': 1, '5': 9, '10': 'stableID'},
  ],
};

/// Descriptor for `SetTailscaleExitNodeRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List setTailscaleExitNodeRequestDescriptor =
    $convert.base64Decode(
        'ChtTZXRUYWlsc2NhbGVFeGl0Tm9kZVJlcXVlc3QSIAoLZW5kcG9pbnRUYWcYASABKAlSC2VuZH'
        'BvaW50VGFnEhoKCHN0YWJsZUlEGAIgASgJUghzdGFibGVJRA==');

@$core.Deprecated('Use tailscaleLogoutRequestDescriptor instead')
const TailscaleLogoutRequest$json = {
  '1': 'TailscaleLogoutRequest',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
  ],
};

/// Descriptor for `TailscaleLogoutRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleLogoutRequestDescriptor =
    $convert.base64Decode(
        'ChZUYWlsc2NhbGVMb2dvdXRSZXF1ZXN0EiAKC2VuZHBvaW50VGFnGAEgASgJUgtlbmRwb2ludF'
        'RhZw==');

@$core.Deprecated('Use tailscaleCertificateRequestDescriptor instead')
const TailscaleCertificateRequest$json = {
  '1': 'TailscaleCertificateRequest',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'domain', '3': 2, '4': 1, '5': 9, '10': 'domain'},
    {
      '1': 'minValiditySeconds',
      '3': 3,
      '4': 1,
      '5': 3,
      '10': 'minValiditySeconds'
    },
  ],
};

/// Descriptor for `TailscaleCertificateRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleCertificateRequestDescriptor =
    $convert.base64Decode(
        'ChtUYWlsc2NhbGVDZXJ0aWZpY2F0ZVJlcXVlc3QSIAoLZW5kcG9pbnRUYWcYASABKAlSC2VuZH'
        'BvaW50VGFnEhYKBmRvbWFpbhgCIAEoCVIGZG9tYWluEi4KEm1pblZhbGlkaXR5U2Vjb25kcxgD'
        'IAEoA1ISbWluVmFsaWRpdHlTZWNvbmRz');

@$core.Deprecated('Use tailscaleCertificateDescriptor instead')
const TailscaleCertificate$json = {
  '1': 'TailscaleCertificate',
  '2': [
    {'1': 'certificatePEM', '3': 1, '4': 1, '5': 12, '10': 'certificatePEM'},
    {'1': 'privateKeyPEM', '3': 2, '4': 1, '5': 12, '10': 'privateKeyPEM'},
  ],
};

/// Descriptor for `TailscaleCertificate`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleCertificateDescriptor = $convert.base64Decode(
    'ChRUYWlsc2NhbGVDZXJ0aWZpY2F0ZRImCg5jZXJ0aWZpY2F0ZVBFTRgBIAEoDFIOY2VydGlmaW'
    'NhdGVQRU0SJAoNcHJpdmF0ZUtleVBFTRgCIAEoDFINcHJpdmF0ZUtleVBFTQ==');

@$core.Deprecated('Use tailscaleSSHClientMessageDescriptor instead')
const TailscaleSSHClientMessage$json = {
  '1': 'TailscaleSSHClientMessage',
  '2': [
    {
      '1': 'start',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.daemon.TailscaleSSHStart',
      '9': 0,
      '10': 'start'
    },
    {
      '1': 'input',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.daemon.TailscaleSSHInput',
      '9': 0,
      '10': 'input'
    },
    {
      '1': 'resize',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.daemon.TailscaleSSHResize',
      '9': 0,
      '10': 'resize'
    },
  ],
  '8': [
    {'1': 'message'},
  ],
};

/// Descriptor for `TailscaleSSHClientMessage`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleSSHClientMessageDescriptor = $convert.base64Decode(
    'ChlUYWlsc2NhbGVTU0hDbGllbnRNZXNzYWdlEjEKBXN0YXJ0GAEgASgLMhkuZGFlbW9uLlRhaW'
    'xzY2FsZVNTSFN0YXJ0SABSBXN0YXJ0EjEKBWlucHV0GAIgASgLMhkuZGFlbW9uLlRhaWxzY2Fs'
    'ZVNTSElucHV0SABSBWlucHV0EjQKBnJlc2l6ZRgDIAEoCzIaLmRhZW1vbi5UYWlsc2NhbGVTU0'
    'hSZXNpemVIAFIGcmVzaXplQgkKB21lc3NhZ2U=');

@$core.Deprecated('Use tailscaleSSHStartDescriptor instead')
const TailscaleSSHStart$json = {
  '1': 'TailscaleSSHStart',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'peerAddress', '3': 2, '4': 1, '5': 9, '10': 'peerAddress'},
    {'1': 'username', '3': 3, '4': 1, '5': 9, '10': 'username'},
    {'1': 'terminalType', '3': 4, '4': 1, '5': 9, '10': 'terminalType'},
    {'1': 'columns', '3': 5, '4': 1, '5': 5, '10': 'columns'},
    {'1': 'rows', '3': 6, '4': 1, '5': 5, '10': 'rows'},
    {'1': 'widthPixels', '3': 7, '4': 1, '5': 5, '10': 'widthPixels'},
    {'1': 'heightPixels', '3': 8, '4': 1, '5': 5, '10': 'heightPixels'},
    {'1': 'hostKeys', '3': 9, '4': 3, '5': 9, '10': 'hostKeys'},
    {'1': 'forward_agent', '3': 10, '4': 1, '5': 8, '10': 'forwardAgent'},
  ],
};

/// Descriptor for `TailscaleSSHStart`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleSSHStartDescriptor = $convert.base64Decode(
    'ChFUYWlsc2NhbGVTU0hTdGFydBIgCgtlbmRwb2ludFRhZxgBIAEoCVILZW5kcG9pbnRUYWcSIA'
    'oLcGVlckFkZHJlc3MYAiABKAlSC3BlZXJBZGRyZXNzEhoKCHVzZXJuYW1lGAMgASgJUgh1c2Vy'
    'bmFtZRIiCgx0ZXJtaW5hbFR5cGUYBCABKAlSDHRlcm1pbmFsVHlwZRIYCgdjb2x1bW5zGAUgAS'
    'gFUgdjb2x1bW5zEhIKBHJvd3MYBiABKAVSBHJvd3MSIAoLd2lkdGhQaXhlbHMYByABKAVSC3dp'
    'ZHRoUGl4ZWxzEiIKDGhlaWdodFBpeGVscxgIIAEoBVIMaGVpZ2h0UGl4ZWxzEhoKCGhvc3RLZX'
    'lzGAkgAygJUghob3N0S2V5cxIjCg1mb3J3YXJkX2FnZW50GAogASgIUgxmb3J3YXJkQWdlbnQ=');

@$core.Deprecated('Use tailscaleSSHInputDescriptor instead')
const TailscaleSSHInput$json = {
  '1': 'TailscaleSSHInput',
  '2': [
    {'1': 'data', '3': 1, '4': 1, '5': 12, '10': 'data'},
  ],
};

/// Descriptor for `TailscaleSSHInput`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleSSHInputDescriptor = $convert
    .base64Decode('ChFUYWlsc2NhbGVTU0hJbnB1dBISCgRkYXRhGAEgASgMUgRkYXRh');

@$core.Deprecated('Use tailscaleSSHResizeDescriptor instead')
const TailscaleSSHResize$json = {
  '1': 'TailscaleSSHResize',
  '2': [
    {'1': 'columns', '3': 1, '4': 1, '5': 5, '10': 'columns'},
    {'1': 'rows', '3': 2, '4': 1, '5': 5, '10': 'rows'},
    {'1': 'widthPixels', '3': 3, '4': 1, '5': 5, '10': 'widthPixels'},
    {'1': 'heightPixels', '3': 4, '4': 1, '5': 5, '10': 'heightPixels'},
  ],
};

/// Descriptor for `TailscaleSSHResize`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleSSHResizeDescriptor = $convert.base64Decode(
    'ChJUYWlsc2NhbGVTU0hSZXNpemUSGAoHY29sdW1ucxgBIAEoBVIHY29sdW1ucxISCgRyb3dzGA'
    'IgASgFUgRyb3dzEiAKC3dpZHRoUGl4ZWxzGAMgASgFUgt3aWR0aFBpeGVscxIiCgxoZWlnaHRQ'
    'aXhlbHMYBCABKAVSDGhlaWdodFBpeGVscw==');

@$core.Deprecated('Use tailscaleSSHServerMessageDescriptor instead')
const TailscaleSSHServerMessage$json = {
  '1': 'TailscaleSSHServerMessage',
  '2': [
    {
      '1': 'authBanner',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.daemon.TailscaleSSHAuthBanner',
      '9': 0,
      '10': 'authBanner'
    },
    {
      '1': 'ready',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.daemon.TailscaleSSHReady',
      '9': 0,
      '10': 'ready'
    },
    {
      '1': 'output',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.daemon.TailscaleSSHOutput',
      '9': 0,
      '10': 'output'
    },
    {
      '1': 'exit',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.daemon.TailscaleSSHExit',
      '9': 0,
      '10': 'exit'
    },
    {
      '1': 'error',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.daemon.TailscaleSSHError',
      '9': 0,
      '10': 'error'
    },
  ],
  '8': [
    {'1': 'message'},
  ],
};

/// Descriptor for `TailscaleSSHServerMessage`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleSSHServerMessageDescriptor = $convert.base64Decode(
    'ChlUYWlsc2NhbGVTU0hTZXJ2ZXJNZXNzYWdlEkAKCmF1dGhCYW5uZXIYASABKAsyHi5kYWVtb2'
    '4uVGFpbHNjYWxlU1NIQXV0aEJhbm5lckgAUgphdXRoQmFubmVyEjEKBXJlYWR5GAIgASgLMhku'
    'ZGFlbW9uLlRhaWxzY2FsZVNTSFJlYWR5SABSBXJlYWR5EjQKBm91dHB1dBgDIAEoCzIaLmRhZW'
    '1vbi5UYWlsc2NhbGVTU0hPdXRwdXRIAFIGb3V0cHV0Ei4KBGV4aXQYBCABKAsyGC5kYWVtb24u'
    'VGFpbHNjYWxlU1NIRXhpdEgAUgRleGl0EjEKBWVycm9yGAUgASgLMhkuZGFlbW9uLlRhaWxzY2'
    'FsZVNTSEVycm9ySABSBWVycm9yQgkKB21lc3NhZ2U=');

@$core.Deprecated('Use tailscaleSSHAuthBannerDescriptor instead')
const TailscaleSSHAuthBanner$json = {
  '1': 'TailscaleSSHAuthBanner',
  '2': [
    {'1': 'message', '3': 1, '4': 1, '5': 9, '10': 'message'},
  ],
};

/// Descriptor for `TailscaleSSHAuthBanner`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleSSHAuthBannerDescriptor =
    $convert.base64Decode(
        'ChZUYWlsc2NhbGVTU0hBdXRoQmFubmVyEhgKB21lc3NhZ2UYASABKAlSB21lc3NhZ2U=');

@$core.Deprecated('Use tailscaleSSHReadyDescriptor instead')
const TailscaleSSHReady$json = {
  '1': 'TailscaleSSHReady',
};

/// Descriptor for `TailscaleSSHReady`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleSSHReadyDescriptor =
    $convert.base64Decode('ChFUYWlsc2NhbGVTU0hSZWFkeQ==');

@$core.Deprecated('Use tailscaleSSHOutputDescriptor instead')
const TailscaleSSHOutput$json = {
  '1': 'TailscaleSSHOutput',
  '2': [
    {'1': 'data', '3': 1, '4': 1, '5': 12, '10': 'data'},
  ],
};

/// Descriptor for `TailscaleSSHOutput`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleSSHOutputDescriptor = $convert
    .base64Decode('ChJUYWlsc2NhbGVTU0hPdXRwdXQSEgoEZGF0YRgBIAEoDFIEZGF0YQ==');

@$core.Deprecated('Use tailscaleSSHExitDescriptor instead')
const TailscaleSSHExit$json = {
  '1': 'TailscaleSSHExit',
  '2': [
    {'1': 'exitCode', '3': 1, '4': 1, '5': 5, '10': 'exitCode'},
    {'1': 'signal', '3': 2, '4': 1, '5': 9, '10': 'signal'},
    {'1': 'errorMessage', '3': 3, '4': 1, '5': 9, '10': 'errorMessage'},
  ],
};

/// Descriptor for `TailscaleSSHExit`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleSSHExitDescriptor = $convert.base64Decode(
    'ChBUYWlsc2NhbGVTU0hFeGl0EhoKCGV4aXRDb2RlGAEgASgFUghleGl0Q29kZRIWCgZzaWduYW'
    'wYAiABKAlSBnNpZ25hbBIiCgxlcnJvck1lc3NhZ2UYAyABKAlSDGVycm9yTWVzc2FnZQ==');

@$core.Deprecated('Use tailscaleSSHErrorDescriptor instead')
const TailscaleSSHError$json = {
  '1': 'TailscaleSSHError',
  '2': [
    {'1': 'message', '3': 1, '4': 1, '5': 9, '10': 'message'},
  ],
};

/// Descriptor for `TailscaleSSHError`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailscaleSSHErrorDescriptor = $convert.base64Decode(
    'ChFUYWlsc2NhbGVTU0hFcnJvchIYCgdtZXNzYWdlGAEgASgJUgdtZXNzYWdl');

@$core.Deprecated('Use subscribeTaildropInboxRequestDescriptor instead')
const SubscribeTaildropInboxRequest$json = {
  '1': 'SubscribeTaildropInboxRequest',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
  ],
};

/// Descriptor for `SubscribeTaildropInboxRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subscribeTaildropInboxRequestDescriptor =
    $convert.base64Decode(
        'Ch1TdWJzY3JpYmVUYWlsZHJvcEluYm94UmVxdWVzdBIgCgtlbmRwb2ludFRhZxgBIAEoCVILZW'
        '5kcG9pbnRUYWc=');

@$core.Deprecated('Use markTaildropInboxReadRequestDescriptor instead')
const MarkTaildropInboxReadRequest$json = {
  '1': 'MarkTaildropInboxReadRequest',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
  ],
};

/// Descriptor for `MarkTaildropInboxReadRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List markTaildropInboxReadRequestDescriptor =
    $convert.base64Decode(
        'ChxNYXJrVGFpbGRyb3BJbmJveFJlYWRSZXF1ZXN0EiAKC2VuZHBvaW50VGFnGAEgASgJUgtlbm'
        'Rwb2ludFRhZw==');

@$core.Deprecated('Use taildropInboxDescriptor instead')
const TaildropInbox$json = {
  '1': 'TaildropInbox',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {
      '1': 'files',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.daemon.TaildropFile',
      '10': 'files'
    },
    {
      '1': 'receiving',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.daemon.TaildropReceivingFile',
      '10': 'receiving'
    },
  ],
};

/// Descriptor for `TaildropInbox`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taildropInboxDescriptor = $convert.base64Decode(
    'Cg1UYWlsZHJvcEluYm94EiAKC2VuZHBvaW50VGFnGAEgASgJUgtlbmRwb2ludFRhZxIqCgVmaW'
    'xlcxgCIAMoCzIULmRhZW1vbi5UYWlsZHJvcEZpbGVSBWZpbGVzEjsKCXJlY2VpdmluZxgDIAMo'
    'CzIdLmRhZW1vbi5UYWlsZHJvcFJlY2VpdmluZ0ZpbGVSCXJlY2VpdmluZw==');

@$core.Deprecated('Use taildropFileDescriptor instead')
const TaildropFile$json = {
  '1': 'TaildropFile',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'size', '3': 2, '4': 1, '5': 3, '10': 'size'},
    {'1': 'senderName', '3': 3, '4': 1, '5': 9, '10': 'senderName'},
    {'1': 'modifiedAt', '3': 4, '4': 1, '5': 3, '10': 'modifiedAt'},
  ],
};

/// Descriptor for `TaildropFile`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taildropFileDescriptor = $convert.base64Decode(
    'CgxUYWlsZHJvcEZpbGUSEgoEbmFtZRgBIAEoCVIEbmFtZRISCgRzaXplGAIgASgDUgRzaXplEh'
    '4KCnNlbmRlck5hbWUYAyABKAlSCnNlbmRlck5hbWUSHgoKbW9kaWZpZWRBdBgEIAEoA1IKbW9k'
    'aWZpZWRBdA==');

@$core.Deprecated('Use taildropReceivingFileDescriptor instead')
const TaildropReceivingFile$json = {
  '1': 'TaildropReceivingFile',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'size', '3': 2, '4': 1, '5': 3, '10': 'size'},
    {'1': 'receivedBytes', '3': 3, '4': 1, '5': 3, '10': 'receivedBytes'},
    {'1': 'senderID', '3': 4, '4': 1, '5': 9, '10': 'senderID'},
    {'1': 'senderName', '3': 5, '4': 1, '5': 9, '10': 'senderName'},
  ],
};

/// Descriptor for `TaildropReceivingFile`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taildropReceivingFileDescriptor = $convert.base64Decode(
    'ChVUYWlsZHJvcFJlY2VpdmluZ0ZpbGUSEgoEbmFtZRgBIAEoCVIEbmFtZRISCgRzaXplGAIgAS'
    'gDUgRzaXplEiQKDXJlY2VpdmVkQnl0ZXMYAyABKANSDXJlY2VpdmVkQnl0ZXMSGgoIc2VuZGVy'
    'SUQYBCABKAlSCHNlbmRlcklEEh4KCnNlbmRlck5hbWUYBSABKAlSCnNlbmRlck5hbWU=');

@$core.Deprecated('Use taildropSendClientMessageDescriptor instead')
const TaildropSendClientMessage$json = {
  '1': 'TaildropSendClientMessage',
  '2': [
    {
      '1': 'start',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.daemon.TaildropSendStart',
      '9': 0,
      '10': 'start'
    },
    {
      '1': 'chunk',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.daemon.TaildropFileChunk',
      '9': 0,
      '10': 'chunk'
    },
    {
      '1': 'fileDone',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.daemon.TaildropFileDone',
      '9': 0,
      '10': 'fileDone'
    },
  ],
  '8': [
    {'1': 'message'},
  ],
};

/// Descriptor for `TaildropSendClientMessage`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taildropSendClientMessageDescriptor = $convert.base64Decode(
    'ChlUYWlsZHJvcFNlbmRDbGllbnRNZXNzYWdlEjEKBXN0YXJ0GAEgASgLMhkuZGFlbW9uLlRhaW'
    'xkcm9wU2VuZFN0YXJ0SABSBXN0YXJ0EjEKBWNodW5rGAIgASgLMhkuZGFlbW9uLlRhaWxkcm9w'
    'RmlsZUNodW5rSABSBWNodW5rEjYKCGZpbGVEb25lGAMgASgLMhguZGFlbW9uLlRhaWxkcm9wRm'
    'lsZURvbmVIAFIIZmlsZURvbmVCCQoHbWVzc2FnZQ==');

@$core.Deprecated('Use taildropSendStartDescriptor instead')
const TaildropSendStart$json = {
  '1': 'TaildropSendStart',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'peerStableID', '3': 2, '4': 1, '5': 9, '10': 'peerStableID'},
    {
      '1': 'files',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.daemon.TaildropOutgoingFile',
      '10': 'files'
    },
  ],
};

/// Descriptor for `TaildropSendStart`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taildropSendStartDescriptor = $convert.base64Decode(
    'ChFUYWlsZHJvcFNlbmRTdGFydBIgCgtlbmRwb2ludFRhZxgBIAEoCVILZW5kcG9pbnRUYWcSIg'
    'oMcGVlclN0YWJsZUlEGAIgASgJUgxwZWVyU3RhYmxlSUQSMgoFZmlsZXMYAyADKAsyHC5kYWVt'
    'b24uVGFpbGRyb3BPdXRnb2luZ0ZpbGVSBWZpbGVz');

@$core.Deprecated('Use taildropOutgoingFileDescriptor instead')
const TaildropOutgoingFile$json = {
  '1': 'TaildropOutgoingFile',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'size', '3': 2, '4': 1, '5': 3, '10': 'size'},
  ],
};

/// Descriptor for `TaildropOutgoingFile`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taildropOutgoingFileDescriptor = $convert.base64Decode(
    'ChRUYWlsZHJvcE91dGdvaW5nRmlsZRISCgRuYW1lGAEgASgJUgRuYW1lEhIKBHNpemUYAiABKA'
    'NSBHNpemU=');

@$core.Deprecated('Use taildropFileChunkDescriptor instead')
const TaildropFileChunk$json = {
  '1': 'TaildropFileChunk',
  '2': [
    {'1': 'data', '3': 1, '4': 1, '5': 12, '10': 'data'},
  ],
};

/// Descriptor for `TaildropFileChunk`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taildropFileChunkDescriptor = $convert
    .base64Decode('ChFUYWlsZHJvcEZpbGVDaHVuaxISCgRkYXRhGAEgASgMUgRkYXRh');

@$core.Deprecated('Use taildropFileDoneDescriptor instead')
const TaildropFileDone$json = {
  '1': 'TaildropFileDone',
};

/// Descriptor for `TaildropFileDone`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taildropFileDoneDescriptor =
    $convert.base64Decode('ChBUYWlsZHJvcEZpbGVEb25l');

@$core.Deprecated('Use taildropSendServerMessageDescriptor instead')
const TaildropSendServerMessage$json = {
  '1': 'TaildropSendServerMessage',
  '2': [
    {
      '1': 'progress',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.daemon.TaildropSendProgress',
      '9': 0,
      '10': 'progress'
    },
    {
      '1': 'receivedBytes',
      '3': 2,
      '4': 1,
      '5': 3,
      '9': 0,
      '10': 'receivedBytes'
    },
  ],
  '8': [
    {'1': 'message'},
  ],
};

/// Descriptor for `TaildropSendServerMessage`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taildropSendServerMessageDescriptor = $convert.base64Decode(
    'ChlUYWlsZHJvcFNlbmRTZXJ2ZXJNZXNzYWdlEjoKCHByb2dyZXNzGAEgASgLMhwuZGFlbW9uLl'
    'RhaWxkcm9wU2VuZFByb2dyZXNzSABSCHByb2dyZXNzEiYKDXJlY2VpdmVkQnl0ZXMYAiABKANI'
    'AFINcmVjZWl2ZWRCeXRlc0IJCgdtZXNzYWdl');

@$core.Deprecated('Use taildropSendProgressDescriptor instead')
const TaildropSendProgress$json = {
  '1': 'TaildropSendProgress',
  '2': [
    {'1': 'fileIndex', '3': 1, '4': 1, '5': 5, '10': 'fileIndex'},
    {'1': 'sentBytes', '3': 2, '4': 1, '5': 3, '10': 'sentBytes'},
    {'1': 'fileCompleted', '3': 3, '4': 1, '5': 8, '10': 'fileCompleted'},
  ],
};

/// Descriptor for `TaildropSendProgress`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taildropSendProgressDescriptor = $convert.base64Decode(
    'ChRUYWlsZHJvcFNlbmRQcm9ncmVzcxIcCglmaWxlSW5kZXgYASABKAVSCWZpbGVJbmRleBIcCg'
    'lzZW50Qnl0ZXMYAiABKANSCXNlbnRCeXRlcxIkCg1maWxlQ29tcGxldGVkGAMgASgIUg1maWxl'
    'Q29tcGxldGVk');

@$core.Deprecated('Use downloadTaildropFileRequestDescriptor instead')
const DownloadTaildropFileRequest$json = {
  '1': 'DownloadTaildropFileRequest',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
  ],
};

/// Descriptor for `DownloadTaildropFileRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List downloadTaildropFileRequestDescriptor =
    $convert.base64Decode(
        'ChtEb3dubG9hZFRhaWxkcm9wRmlsZVJlcXVlc3QSIAoLZW5kcG9pbnRUYWcYASABKAlSC2VuZH'
        'BvaW50VGFnEhIKBG5hbWUYAiABKAlSBG5hbWU=');

@$core.Deprecated('Use downloadTaildropFileChunkDescriptor instead')
const DownloadTaildropFileChunk$json = {
  '1': 'DownloadTaildropFileChunk',
  '2': [
    {'1': 'size', '3': 1, '4': 1, '5': 3, '10': 'size'},
    {'1': 'data', '3': 2, '4': 1, '5': 12, '10': 'data'},
  ],
};

/// Descriptor for `DownloadTaildropFileChunk`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List downloadTaildropFileChunkDescriptor =
    $convert.base64Decode(
        'ChlEb3dubG9hZFRhaWxkcm9wRmlsZUNodW5rEhIKBHNpemUYASABKANSBHNpemUSEgoEZGF0YR'
        'gCIAEoDFIEZGF0YQ==');

@$core.Deprecated('Use deleteTaildropFileRequestDescriptor instead')
const DeleteTaildropFileRequest$json = {
  '1': 'DeleteTaildropFileRequest',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
  ],
};

/// Descriptor for `DeleteTaildropFileRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deleteTaildropFileRequestDescriptor =
    $convert.base64Decode(
        'ChlEZWxldGVUYWlsZHJvcEZpbGVSZXF1ZXN0EiAKC2VuZHBvaW50VGFnGAEgASgJUgtlbmRwb2'
        'ludFRhZxISCgRuYW1lGAIgASgJUgRuYW1l');

@$core.Deprecated('Use cancelTaildropReceivingRequestDescriptor instead')
const CancelTaildropReceivingRequest$json = {
  '1': 'CancelTaildropReceivingRequest',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'senderID', '3': 2, '4': 1, '5': 9, '10': 'senderID'},
    {'1': 'name', '3': 3, '4': 1, '5': 9, '10': 'name'},
  ],
};

/// Descriptor for `CancelTaildropReceivingRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List cancelTaildropReceivingRequestDescriptor =
    $convert.base64Decode(
        'Ch5DYW5jZWxUYWlsZHJvcFJlY2VpdmluZ1JlcXVlc3QSIAoLZW5kcG9pbnRUYWcYASABKAlSC2'
        'VuZHBvaW50VGFnEhoKCHNlbmRlcklEGAIgASgJUghzZW5kZXJJRBISCgRuYW1lGAMgASgJUgRu'
        'YW1l');

@$core.Deprecated('Use uSBProviderMessageDescriptor instead')
const USBProviderMessage$json = {
  '1': 'USBProviderMessage',
  '2': [
    {
      '1': 'attach',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.daemon.USBDeviceAttach',
      '9': 0,
      '10': 'attach'
    },
    {
      '1': 'detach',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.daemon.USBDeviceDetach',
      '9': 0,
      '10': 'detach'
    },
    {
      '1': 'urbResponse',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.daemon.USBURBResponse',
      '9': 0,
      '10': 'urbResponse'
    },
  ],
  '8': [
    {'1': 'message'},
  ],
};

/// Descriptor for `USBProviderMessage`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBProviderMessageDescriptor = $convert.base64Decode(
    'ChJVU0JQcm92aWRlck1lc3NhZ2USMQoGYXR0YWNoGAEgASgLMhcuZGFlbW9uLlVTQkRldmljZU'
    'F0dGFjaEgAUgZhdHRhY2gSMQoGZGV0YWNoGAIgASgLMhcuZGFlbW9uLlVTQkRldmljZURldGFj'
    'aEgAUgZkZXRhY2gSOgoLdXJiUmVzcG9uc2UYAyABKAsyFi5kYWVtb24uVVNCVVJCUmVzcG9uc2'
    'VIAFILdXJiUmVzcG9uc2VCCQoHbWVzc2FnZQ==');

@$core.Deprecated('Use uSBServerMessageDescriptor instead')
const USBServerMessage$json = {
  '1': 'USBServerMessage',
  '2': [
    {
      '1': 'ready',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.daemon.USBDeviceReady',
      '9': 0,
      '10': 'ready'
    },
    {
      '1': 'urbRequest',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.daemon.USBURBRequest',
      '9': 0,
      '10': 'urbRequest'
    },
    {
      '1': 'abort',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.daemon.USBEndpointAbort',
      '9': 0,
      '10': 'abort'
    },
    {
      '1': 'error',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.daemon.USBError',
      '9': 0,
      '10': 'error'
    },
  ],
  '8': [
    {'1': 'message'},
  ],
};

/// Descriptor for `USBServerMessage`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBServerMessageDescriptor = $convert.base64Decode(
    'ChBVU0JTZXJ2ZXJNZXNzYWdlEi4KBXJlYWR5GAEgASgLMhYuZGFlbW9uLlVTQkRldmljZVJlYW'
    'R5SABSBXJlYWR5EjcKCnVyYlJlcXVlc3QYAiABKAsyFS5kYWVtb24uVVNCVVJCUmVxdWVzdEgA'
    'Ugp1cmJSZXF1ZXN0EjAKBWFib3J0GAMgASgLMhguZGFlbW9uLlVTQkVuZHBvaW50QWJvcnRIAF'
    'IFYWJvcnQSKAoFZXJyb3IYBCABKAsyEC5kYWVtb24uVVNCRXJyb3JIAFIFZXJyb3JCCQoHbWVz'
    'c2FnZQ==');

@$core.Deprecated('Use uSBDeviceDescriptorDescriptor instead')
const USBDeviceDescriptor$json = {
  '1': 'USBDeviceDescriptor',
  '2': [
    {'1': 'deviceId', '3': 1, '4': 1, '5': 9, '10': 'deviceId'},
    {'1': 'busNum', '3': 2, '4': 1, '5': 13, '10': 'busNum'},
    {'1': 'devNum', '3': 3, '4': 1, '5': 13, '10': 'devNum'},
    {'1': 'speed', '3': 4, '4': 1, '5': 13, '10': 'speed'},
    {'1': 'vendorId', '3': 5, '4': 1, '5': 13, '10': 'vendorId'},
    {'1': 'productId', '3': 6, '4': 1, '5': 13, '10': 'productId'},
    {'1': 'bcdDevice', '3': 7, '4': 1, '5': 13, '10': 'bcdDevice'},
    {'1': 'deviceClass', '3': 8, '4': 1, '5': 13, '10': 'deviceClass'},
    {'1': 'deviceSubClass', '3': 9, '4': 1, '5': 13, '10': 'deviceSubClass'},
    {'1': 'deviceProtocol', '3': 10, '4': 1, '5': 13, '10': 'deviceProtocol'},
    {
      '1': 'configurationValue',
      '3': 11,
      '4': 1,
      '5': 13,
      '10': 'configurationValue'
    },
    {
      '1': 'numConfigurations',
      '3': 12,
      '4': 1,
      '5': 13,
      '10': 'numConfigurations'
    },
    {
      '1': 'interfaces',
      '3': 13,
      '4': 3,
      '5': 11,
      '6': '.daemon.USBInterface',
      '10': 'interfaces'
    },
    {'1': 'serial', '3': 14, '4': 1, '5': 9, '10': 'serial'},
    {'1': 'product', '3': 15, '4': 1, '5': 9, '10': 'product'},
  ],
};

/// Descriptor for `USBDeviceDescriptor`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBDeviceDescriptorDescriptor = $convert.base64Decode(
    'ChNVU0JEZXZpY2VEZXNjcmlwdG9yEhoKCGRldmljZUlkGAEgASgJUghkZXZpY2VJZBIWCgZidX'
    'NOdW0YAiABKA1SBmJ1c051bRIWCgZkZXZOdW0YAyABKA1SBmRldk51bRIUCgVzcGVlZBgEIAEo'
    'DVIFc3BlZWQSGgoIdmVuZG9ySWQYBSABKA1SCHZlbmRvcklkEhwKCXByb2R1Y3RJZBgGIAEoDV'
    'IJcHJvZHVjdElkEhwKCWJjZERldmljZRgHIAEoDVIJYmNkRGV2aWNlEiAKC2RldmljZUNsYXNz'
    'GAggASgNUgtkZXZpY2VDbGFzcxImCg5kZXZpY2VTdWJDbGFzcxgJIAEoDVIOZGV2aWNlU3ViQ2'
    'xhc3MSJgoOZGV2aWNlUHJvdG9jb2wYCiABKA1SDmRldmljZVByb3RvY29sEi4KEmNvbmZpZ3Vy'
    'YXRpb25WYWx1ZRgLIAEoDVISY29uZmlndXJhdGlvblZhbHVlEiwKEW51bUNvbmZpZ3VyYXRpb2'
    '5zGAwgASgNUhFudW1Db25maWd1cmF0aW9ucxI0CgppbnRlcmZhY2VzGA0gAygLMhQuZGFlbW9u'
    'LlVTQkludGVyZmFjZVIKaW50ZXJmYWNlcxIWCgZzZXJpYWwYDiABKAlSBnNlcmlhbBIYCgdwcm'
    '9kdWN0GA8gASgJUgdwcm9kdWN0');

@$core.Deprecated('Use uSBDeviceAttachDescriptor instead')
const USBDeviceAttach$json = {
  '1': 'USBDeviceAttach',
  '2': [
    {'1': 'serverTag', '3': 1, '4': 1, '5': 9, '10': 'serverTag'},
    {
      '1': 'descriptor',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.daemon.USBDeviceDescriptor',
      '10': 'descriptor'
    },
  ],
};

/// Descriptor for `USBDeviceAttach`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBDeviceAttachDescriptor = $convert.base64Decode(
    'Cg9VU0JEZXZpY2VBdHRhY2gSHAoJc2VydmVyVGFnGAEgASgJUglzZXJ2ZXJUYWcSOwoKZGVzY3'
    'JpcHRvchgCIAEoCzIbLmRhZW1vbi5VU0JEZXZpY2VEZXNjcmlwdG9yUgpkZXNjcmlwdG9y');

@$core.Deprecated('Use uSBInterfaceDescriptor instead')
const USBInterface$json = {
  '1': 'USBInterface',
  '2': [
    {'1': 'interfaceClass', '3': 1, '4': 1, '5': 13, '10': 'interfaceClass'},
    {
      '1': 'interfaceSubClass',
      '3': 2,
      '4': 1,
      '5': 13,
      '10': 'interfaceSubClass'
    },
    {
      '1': 'interfaceProtocol',
      '3': 3,
      '4': 1,
      '5': 13,
      '10': 'interfaceProtocol'
    },
  ],
};

/// Descriptor for `USBInterface`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBInterfaceDescriptor = $convert.base64Decode(
    'CgxVU0JJbnRlcmZhY2USJgoOaW50ZXJmYWNlQ2xhc3MYASABKA1SDmludGVyZmFjZUNsYXNzEi'
    'wKEWludGVyZmFjZVN1YkNsYXNzGAIgASgNUhFpbnRlcmZhY2VTdWJDbGFzcxIsChFpbnRlcmZh'
    'Y2VQcm90b2NvbBgDIAEoDVIRaW50ZXJmYWNlUHJvdG9jb2w=');

@$core.Deprecated('Use uSBDeviceDetachDescriptor instead')
const USBDeviceDetach$json = {
  '1': 'USBDeviceDetach',
  '2': [
    {'1': 'deviceId', '3': 1, '4': 1, '5': 9, '10': 'deviceId'},
  ],
};

/// Descriptor for `USBDeviceDetach`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBDeviceDetachDescriptor = $convert.base64Decode(
    'Cg9VU0JEZXZpY2VEZXRhY2gSGgoIZGV2aWNlSWQYASABKAlSCGRldmljZUlk');

@$core.Deprecated('Use uSBDeviceReadyDescriptor instead')
const USBDeviceReady$json = {
  '1': 'USBDeviceReady',
  '2': [
    {'1': 'deviceId', '3': 1, '4': 1, '5': 9, '10': 'deviceId'},
    {'1': 'busId', '3': 2, '4': 1, '5': 9, '10': 'busId'},
  ],
};

/// Descriptor for `USBDeviceReady`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBDeviceReadyDescriptor = $convert.base64Decode(
    'Cg5VU0JEZXZpY2VSZWFkeRIaCghkZXZpY2VJZBgBIAEoCVIIZGV2aWNlSWQSFAoFYnVzSWQYAi'
    'ABKAlSBWJ1c0lk');

@$core.Deprecated('Use uSBURBRequestDescriptor instead')
const USBURBRequest$json = {
  '1': 'USBURBRequest',
  '2': [
    {'1': 'deviceId', '3': 1, '4': 1, '5': 9, '10': 'deviceId'},
    {'1': 'seq', '3': 2, '4': 1, '5': 4, '10': 'seq'},
    {'1': 'endpoint', '3': 3, '4': 1, '5': 13, '10': 'endpoint'},
    {'1': 'directionIn', '3': 4, '4': 1, '5': 8, '10': 'directionIn'},
    {'1': 'transferFlags', '3': 5, '4': 1, '5': 13, '10': 'transferFlags'},
    {'1': 'setup', '3': 6, '4': 1, '5': 12, '10': 'setup'},
    {
      '1': 'transferBufferLength',
      '3': 7,
      '4': 1,
      '5': 13,
      '10': 'transferBufferLength'
    },
    {'1': 'outData', '3': 8, '4': 1, '5': 12, '10': 'outData'},
    {'1': 'numberOfPackets', '3': 9, '4': 1, '5': 5, '10': 'numberOfPackets'},
    {'1': 'startFrame', '3': 10, '4': 1, '5': 5, '10': 'startFrame'},
    {'1': 'interval', '3': 11, '4': 1, '5': 5, '10': 'interval'},
    {
      '1': 'isoPackets',
      '3': 12,
      '4': 3,
      '5': 11,
      '6': '.daemon.USBIsoPacket',
      '10': 'isoPackets'
    },
  ],
};

/// Descriptor for `USBURBRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBURBRequestDescriptor = $convert.base64Decode(
    'Cg1VU0JVUkJSZXF1ZXN0EhoKCGRldmljZUlkGAEgASgJUghkZXZpY2VJZBIQCgNzZXEYAiABKA'
    'RSA3NlcRIaCghlbmRwb2ludBgDIAEoDVIIZW5kcG9pbnQSIAoLZGlyZWN0aW9uSW4YBCABKAhS'
    'C2RpcmVjdGlvbkluEiQKDXRyYW5zZmVyRmxhZ3MYBSABKA1SDXRyYW5zZmVyRmxhZ3MSFAoFc2'
    'V0dXAYBiABKAxSBXNldHVwEjIKFHRyYW5zZmVyQnVmZmVyTGVuZ3RoGAcgASgNUhR0cmFuc2Zl'
    'ckJ1ZmZlckxlbmd0aBIYCgdvdXREYXRhGAggASgMUgdvdXREYXRhEigKD251bWJlck9mUGFja2'
    'V0cxgJIAEoBVIPbnVtYmVyT2ZQYWNrZXRzEh4KCnN0YXJ0RnJhbWUYCiABKAVSCnN0YXJ0RnJh'
    'bWUSGgoIaW50ZXJ2YWwYCyABKAVSCGludGVydmFsEjQKCmlzb1BhY2tldHMYDCADKAsyFC5kYW'
    'Vtb24uVVNCSXNvUGFja2V0Ugppc29QYWNrZXRz');

@$core.Deprecated('Use uSBURBResponseDescriptor instead')
const USBURBResponse$json = {
  '1': 'USBURBResponse',
  '2': [
    {'1': 'deviceId', '3': 1, '4': 1, '5': 9, '10': 'deviceId'},
    {'1': 'seq', '3': 2, '4': 1, '5': 4, '10': 'seq'},
    {'1': 'status', '3': 3, '4': 1, '5': 5, '10': 'status'},
    {'1': 'actualLength', '3': 4, '4': 1, '5': 5, '10': 'actualLength'},
    {'1': 'inData', '3': 5, '4': 1, '5': 12, '10': 'inData'},
    {
      '1': 'isoPackets',
      '3': 6,
      '4': 3,
      '5': 11,
      '6': '.daemon.USBIsoPacket',
      '10': 'isoPackets'
    },
  ],
};

/// Descriptor for `USBURBResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBURBResponseDescriptor = $convert.base64Decode(
    'Cg5VU0JVUkJSZXNwb25zZRIaCghkZXZpY2VJZBgBIAEoCVIIZGV2aWNlSWQSEAoDc2VxGAIgAS'
    'gEUgNzZXESFgoGc3RhdHVzGAMgASgFUgZzdGF0dXMSIgoMYWN0dWFsTGVuZ3RoGAQgASgFUgxh'
    'Y3R1YWxMZW5ndGgSFgoGaW5EYXRhGAUgASgMUgZpbkRhdGESNAoKaXNvUGFja2V0cxgGIAMoCz'
    'IULmRhZW1vbi5VU0JJc29QYWNrZXRSCmlzb1BhY2tldHM=');

@$core.Deprecated('Use uSBIsoPacketDescriptor instead')
const USBIsoPacket$json = {
  '1': 'USBIsoPacket',
  '2': [
    {'1': 'offset', '3': 1, '4': 1, '5': 5, '10': 'offset'},
    {'1': 'length', '3': 2, '4': 1, '5': 5, '10': 'length'},
    {'1': 'actualLength', '3': 3, '4': 1, '5': 5, '10': 'actualLength'},
    {'1': 'status', '3': 4, '4': 1, '5': 5, '10': 'status'},
  ],
};

/// Descriptor for `USBIsoPacket`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBIsoPacketDescriptor = $convert.base64Decode(
    'CgxVU0JJc29QYWNrZXQSFgoGb2Zmc2V0GAEgASgFUgZvZmZzZXQSFgoGbGVuZ3RoGAIgASgFUg'
    'ZsZW5ndGgSIgoMYWN0dWFsTGVuZ3RoGAMgASgFUgxhY3R1YWxMZW5ndGgSFgoGc3RhdHVzGAQg'
    'ASgFUgZzdGF0dXM=');

@$core.Deprecated('Use uSBEndpointAbortDescriptor instead')
const USBEndpointAbort$json = {
  '1': 'USBEndpointAbort',
  '2': [
    {'1': 'deviceId', '3': 1, '4': 1, '5': 9, '10': 'deviceId'},
    {'1': 'endpoint', '3': 2, '4': 1, '5': 13, '10': 'endpoint'},
  ],
};

/// Descriptor for `USBEndpointAbort`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBEndpointAbortDescriptor = $convert.base64Decode(
    'ChBVU0JFbmRwb2ludEFib3J0EhoKCGRldmljZUlkGAEgASgJUghkZXZpY2VJZBIaCghlbmRwb2'
    'ludBgCIAEoDVIIZW5kcG9pbnQ=');

@$core.Deprecated('Use uSBErrorDescriptor instead')
const USBError$json = {
  '1': 'USBError',
  '2': [
    {'1': 'deviceId', '3': 1, '4': 1, '5': 9, '10': 'deviceId'},
    {'1': 'message', '3': 2, '4': 1, '5': 9, '10': 'message'},
  ],
};

/// Descriptor for `USBError`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBErrorDescriptor = $convert.base64Decode(
    'CghVU0JFcnJvchIaCghkZXZpY2VJZBgBIAEoCVIIZGV2aWNlSWQSGAoHbWVzc2FnZRgCIAEoCV'
    'IHbWVzc2FnZQ==');

@$core.Deprecated('Use uSBIPServerStatusUpdateDescriptor instead')
const USBIPServerStatusUpdate$json = {
  '1': 'USBIPServerStatusUpdate',
  '2': [
    {
      '1': 'servers',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.daemon.USBIPServerStatus',
      '10': 'servers'
    },
  ],
};

/// Descriptor for `USBIPServerStatusUpdate`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBIPServerStatusUpdateDescriptor =
    $convert.base64Decode(
        'ChdVU0JJUFNlcnZlclN0YXR1c1VwZGF0ZRIzCgdzZXJ2ZXJzGAEgAygLMhkuZGFlbW9uLlVTQk'
        'lQU2VydmVyU3RhdHVzUgdzZXJ2ZXJz');

@$core.Deprecated('Use uSBIPServerStatusDescriptor instead')
const USBIPServerStatus$json = {
  '1': 'USBIPServerStatus',
  '2': [
    {'1': 'serverTag', '3': 1, '4': 1, '5': 9, '10': 'serverTag'},
    {
      '1': 'devices',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.daemon.USBSharedDevice',
      '10': 'devices'
    },
  ],
};

/// Descriptor for `USBIPServerStatus`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBIPServerStatusDescriptor = $convert.base64Decode(
    'ChFVU0JJUFNlcnZlclN0YXR1cxIcCglzZXJ2ZXJUYWcYASABKAlSCXNlcnZlclRhZxIxCgdkZX'
    'ZpY2VzGAIgAygLMhcuZGFlbW9uLlVTQlNoYXJlZERldmljZVIHZGV2aWNlcw==');

@$core.Deprecated('Use uSBSharedDeviceDescriptor instead')
const USBSharedDevice$json = {
  '1': 'USBSharedDevice',
  '2': [
    {
      '1': 'descriptor',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.daemon.USBDeviceDescriptor',
      '10': 'descriptor'
    },
    {'1': 'busId', '3': 2, '4': 1, '5': 9, '10': 'busId'},
    {'1': 'stableId', '3': 3, '4': 1, '5': 9, '10': 'stableId'},
    {
      '1': 'backend',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.daemon.USBBackend',
      '10': 'backend'
    },
    {
      '1': 'state',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.daemon.USBDeviceState',
      '10': 'state'
    },
  ],
};

/// Descriptor for `USBSharedDevice`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uSBSharedDeviceDescriptor = $convert.base64Decode(
    'Cg9VU0JTaGFyZWREZXZpY2USOwoKZGVzY3JpcHRvchgBIAEoCzIbLmRhZW1vbi5VU0JEZXZpY2'
    'VEZXNjcmlwdG9yUgpkZXNjcmlwdG9yEhQKBWJ1c0lkGAIgASgJUgVidXNJZBIaCghzdGFibGVJ'
    'ZBgDIAEoCVIIc3RhYmxlSWQSLAoHYmFja2VuZBgEIAEoDjISLmRhZW1vbi5VU0JCYWNrZW5kUg'
    'diYWNrZW5kEiwKBXN0YXRlGAUgASgOMhYuZGFlbW9uLlVTQkRldmljZVN0YXRlUgVzdGF0ZQ==');

@$core.Deprecated('Use openConnectStatusUpdateDescriptor instead')
const OpenConnectStatusUpdate$json = {
  '1': 'OpenConnectStatusUpdate',
  '2': [
    {
      '1': 'endpoints',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.daemon.OpenConnectEndpointStatus',
      '10': 'endpoints'
    },
  ],
};

/// Descriptor for `OpenConnectStatusUpdate`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectStatusUpdateDescriptor =
    $convert.base64Decode(
        'ChdPcGVuQ29ubmVjdFN0YXR1c1VwZGF0ZRI/CgllbmRwb2ludHMYASADKAsyIS5kYWVtb24uT3'
        'BlbkNvbm5lY3RFbmRwb2ludFN0YXR1c1IJZW5kcG9pbnRz');

@$core.Deprecated('Use openConnectEndpointStatusDescriptor instead')
const OpenConnectEndpointStatus$json = {
  '1': 'OpenConnectEndpointStatus',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'state', '3': 2, '4': 1, '5': 9, '10': 'state'},
    {'1': 'stateText', '3': 3, '4': 1, '5': 9, '10': 'stateText'},
    {
      '1': 'authChallenge',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.daemon.OpenConnectAuthChallenge',
      '10': 'authChallenge'
    },
    {'1': 'error', '3': 5, '4': 1, '5': 9, '10': 'error'},
    {
      '1': 'tunnelInfo',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.daemon.OpenConnectTunnelInfo',
      '10': 'tunnelInfo'
    },
  ],
};

/// Descriptor for `OpenConnectEndpointStatus`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectEndpointStatusDescriptor = $convert.base64Decode(
    'ChlPcGVuQ29ubmVjdEVuZHBvaW50U3RhdHVzEiAKC2VuZHBvaW50VGFnGAEgASgJUgtlbmRwb2'
    'ludFRhZxIUCgVzdGF0ZRgCIAEoCVIFc3RhdGUSHAoJc3RhdGVUZXh0GAMgASgJUglzdGF0ZVRl'
    'eHQSRgoNYXV0aENoYWxsZW5nZRgEIAEoCzIgLmRhZW1vbi5PcGVuQ29ubmVjdEF1dGhDaGFsbG'
    'VuZ2VSDWF1dGhDaGFsbGVuZ2USFAoFZXJyb3IYBSABKAlSBWVycm9yEj0KCnR1bm5lbEluZm8Y'
    'BiABKAsyHS5kYWVtb24uT3BlbkNvbm5lY3RUdW5uZWxJbmZvUgp0dW5uZWxJbmZv');

@$core.Deprecated('Use openConnectTunnelInfoDescriptor instead')
const OpenConnectTunnelInfo$json = {
  '1': 'OpenConnectTunnelInfo',
  '2': [
    {'1': 'server', '3': 1, '4': 1, '5': 9, '10': 'server'},
    {'1': 'flavor', '3': 2, '4': 1, '5': 9, '10': 'flavor'},
    {'1': 'transport', '3': 3, '4': 1, '5': 9, '10': 'transport'},
    {'1': 'ipv4', '3': 4, '4': 3, '5': 9, '10': 'ipv4'},
    {'1': 'ipv6', '3': 5, '4': 3, '5': 9, '10': 'ipv6'},
    {'1': 'dns', '3': 6, '4': 3, '5': 9, '10': 'dns'},
    {'1': 'mtu', '3': 7, '4': 1, '5': 13, '10': 'mtu'},
    {'1': 'connectedSince', '3': 8, '4': 1, '5': 3, '10': 'connectedSince'},
  ],
};

/// Descriptor for `OpenConnectTunnelInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectTunnelInfoDescriptor = $convert.base64Decode(
    'ChVPcGVuQ29ubmVjdFR1bm5lbEluZm8SFgoGc2VydmVyGAEgASgJUgZzZXJ2ZXISFgoGZmxhdm'
    '9yGAIgASgJUgZmbGF2b3ISHAoJdHJhbnNwb3J0GAMgASgJUgl0cmFuc3BvcnQSEgoEaXB2NBgE'
    'IAMoCVIEaXB2NBISCgRpcHY2GAUgAygJUgRpcHY2EhAKA2RucxgGIAMoCVIDZG5zEhAKA210dR'
    'gHIAEoDVIDbXR1EiYKDmNvbm5lY3RlZFNpbmNlGAggASgDUg5jb25uZWN0ZWRTaW5jZQ==');

@$core.Deprecated('Use openConnectAuthChallengeDescriptor instead')
const OpenConnectAuthChallenge$json = {
  '1': 'OpenConnectAuthChallenge',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'banner', '3': 2, '4': 1, '5': 9, '10': 'banner'},
    {'1': 'message', '3': 3, '4': 1, '5': 9, '10': 'message'},
    {'1': 'error', '3': 4, '4': 1, '5': 9, '10': 'error'},
    {
      '1': 'form',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.daemon.OpenConnectAuthForm',
      '9': 0,
      '10': 'form'
    },
    {
      '1': 'browser',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.daemon.OpenConnectBrowserRequest',
      '9': 0,
      '10': 'browser'
    },
  ],
  '8': [
    {'1': 'challenge'},
  ],
};

/// Descriptor for `OpenConnectAuthChallenge`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectAuthChallengeDescriptor = $convert.base64Decode(
    'ChhPcGVuQ29ubmVjdEF1dGhDaGFsbGVuZ2USDgoCaWQYASABKAlSAmlkEhYKBmJhbm5lchgCIA'
    'EoCVIGYmFubmVyEhgKB21lc3NhZ2UYAyABKAlSB21lc3NhZ2USFAoFZXJyb3IYBCABKAlSBWVy'
    'cm9yEjEKBGZvcm0YBSABKAsyGy5kYWVtb24uT3BlbkNvbm5lY3RBdXRoRm9ybUgAUgRmb3JtEj'
    '0KB2Jyb3dzZXIYBiABKAsyIS5kYWVtb24uT3BlbkNvbm5lY3RCcm93c2VyUmVxdWVzdEgAUgdi'
    'cm93c2VyQgsKCWNoYWxsZW5nZQ==');

@$core.Deprecated('Use openConnectAuthFormDescriptor instead')
const OpenConnectAuthForm$json = {
  '1': 'OpenConnectAuthForm',
  '2': [
    {
      '1': 'fields',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.daemon.OpenConnectAuthFormField',
      '10': 'fields'
    },
  ],
};

/// Descriptor for `OpenConnectAuthForm`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectAuthFormDescriptor = $convert.base64Decode(
    'ChNPcGVuQ29ubmVjdEF1dGhGb3JtEjgKBmZpZWxkcxgBIAMoCzIgLmRhZW1vbi5PcGVuQ29ubm'
    'VjdEF1dGhGb3JtRmllbGRSBmZpZWxkcw==');

@$core.Deprecated('Use openConnectAuthFormFieldDescriptor instead')
const OpenConnectAuthFormField$json = {
  '1': 'OpenConnectAuthFormField',
  '2': [
    {'1': 'submissionKey', '3': 1, '4': 1, '5': 9, '10': 'submissionKey'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'label', '3': 3, '4': 1, '5': 9, '10': 'label'},
    {'1': 'kind', '3': 4, '4': 1, '5': 9, '10': 'kind'},
    {'1': 'value', '3': 5, '4': 1, '5': 9, '10': 'value'},
    {
      '1': 'options',
      '3': 6,
      '4': 3,
      '5': 11,
      '6': '.daemon.OpenConnectAuthFormChoice',
      '10': 'options'
    },
  ],
};

/// Descriptor for `OpenConnectAuthFormField`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectAuthFormFieldDescriptor = $convert.base64Decode(
    'ChhPcGVuQ29ubmVjdEF1dGhGb3JtRmllbGQSJAoNc3VibWlzc2lvbktleRgBIAEoCVINc3VibW'
    'lzc2lvbktleRISCgRuYW1lGAIgASgJUgRuYW1lEhQKBWxhYmVsGAMgASgJUgVsYWJlbBISCgRr'
    'aW5kGAQgASgJUgRraW5kEhQKBXZhbHVlGAUgASgJUgV2YWx1ZRI7CgdvcHRpb25zGAYgAygLMi'
    'EuZGFlbW9uLk9wZW5Db25uZWN0QXV0aEZvcm1DaG9pY2VSB29wdGlvbnM=');

@$core.Deprecated('Use openConnectAuthFormChoiceDescriptor instead')
const OpenConnectAuthFormChoice$json = {
  '1': 'OpenConnectAuthFormChoice',
  '2': [
    {'1': 'value', '3': 1, '4': 1, '5': 9, '10': 'value'},
    {'1': 'label', '3': 2, '4': 1, '5': 9, '10': 'label'},
  ],
};

/// Descriptor for `OpenConnectAuthFormChoice`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectAuthFormChoiceDescriptor =
    $convert.base64Decode(
        'ChlPcGVuQ29ubmVjdEF1dGhGb3JtQ2hvaWNlEhQKBXZhbHVlGAEgASgJUgV2YWx1ZRIUCgVsYW'
        'JlbBgCIAEoCVIFbGFiZWw=');

@$core.Deprecated('Use openConnectBrowserRequestDescriptor instead')
const OpenConnectBrowserRequest$json = {
  '1': 'OpenConnectBrowserRequest',
  '2': [
    {'1': 'url', '3': 1, '4': 1, '5': 9, '10': 'url'},
    {'1': 'finalURL', '3': 2, '4': 1, '5': 9, '10': 'finalURL'},
    {'1': 'cookieNames', '3': 3, '4': 3, '5': 9, '10': 'cookieNames'},
    {'1': 'headerNames', '3': 4, '4': 3, '5': 9, '10': 'headerNames'},
    {
      '1': 'callbackURLPrefixes',
      '3': 5,
      '4': 3,
      '5': 9,
      '10': 'callbackURLPrefixes'
    },
    {'1': 'earlyCookieNames', '3': 6, '4': 3, '5': 9, '10': 'earlyCookieNames'},
    {'1': 'cacheID', '3': 7, '4': 1, '5': 9, '10': 'cacheID'},
  ],
};

/// Descriptor for `OpenConnectBrowserRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectBrowserRequestDescriptor = $convert.base64Decode(
    'ChlPcGVuQ29ubmVjdEJyb3dzZXJSZXF1ZXN0EhAKA3VybBgBIAEoCVIDdXJsEhoKCGZpbmFsVV'
    'JMGAIgASgJUghmaW5hbFVSTBIgCgtjb29raWVOYW1lcxgDIAMoCVILY29va2llTmFtZXMSIAoL'
    'aGVhZGVyTmFtZXMYBCADKAlSC2hlYWRlck5hbWVzEjAKE2NhbGxiYWNrVVJMUHJlZml4ZXMYBS'
    'ADKAlSE2NhbGxiYWNrVVJMUHJlZml4ZXMSKgoQZWFybHlDb29raWVOYW1lcxgGIAMoCVIQZWFy'
    'bHlDb29raWVOYW1lcxIYCgdjYWNoZUlEGAcgASgJUgdjYWNoZUlE');

@$core.Deprecated('Use openConnectBrowserCookieDescriptor instead')
const OpenConnectBrowserCookie$json = {
  '1': 'OpenConnectBrowserCookie',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
};

/// Descriptor for `OpenConnectBrowserCookie`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectBrowserCookieDescriptor =
    $convert.base64Decode(
        'ChhPcGVuQ29ubmVjdEJyb3dzZXJDb29raWUSEgoEbmFtZRgBIAEoCVIEbmFtZRIUCgV2YWx1ZR'
        'gCIAEoCVIFdmFsdWU=');

@$core.Deprecated('Use openConnectBrowserHeaderDescriptor instead')
const OpenConnectBrowserHeader$json = {
  '1': 'OpenConnectBrowserHeader',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'values', '3': 2, '4': 3, '5': 9, '10': 'values'},
  ],
};

/// Descriptor for `OpenConnectBrowserHeader`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectBrowserHeaderDescriptor =
    $convert.base64Decode(
        'ChhPcGVuQ29ubmVjdEJyb3dzZXJIZWFkZXISEgoEbmFtZRgBIAEoCVIEbmFtZRIWCgZ2YWx1ZX'
        'MYAiADKAlSBnZhbHVlcw==');

@$core.Deprecated('Use openConnectAuthFormResponseDescriptor instead')
const OpenConnectAuthFormResponse$json = {
  '1': 'OpenConnectAuthFormResponse',
  '2': [
    {
      '1': 'values',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.daemon.OpenConnectAuthFormResponse.ValuesEntry',
      '10': 'values'
    },
  ],
  '3': [OpenConnectAuthFormResponse_ValuesEntry$json],
};

@$core.Deprecated('Use openConnectAuthFormResponseDescriptor instead')
const OpenConnectAuthFormResponse_ValuesEntry$json = {
  '1': 'ValuesEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `OpenConnectAuthFormResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectAuthFormResponseDescriptor =
    $convert.base64Decode(
        'ChtPcGVuQ29ubmVjdEF1dGhGb3JtUmVzcG9uc2USRwoGdmFsdWVzGAEgAygLMi8uZGFlbW9uLk'
        '9wZW5Db25uZWN0QXV0aEZvcm1SZXNwb25zZS5WYWx1ZXNFbnRyeVIGdmFsdWVzGjkKC1ZhbHVl'
        'c0VudHJ5EhAKA2tleRgBIAEoCVIDa2V5EhQKBXZhbHVlGAIgASgJUgV2YWx1ZToCOAE=');

@$core.Deprecated('Use openConnectBrowserResultDescriptor instead')
const OpenConnectBrowserResult$json = {
  '1': 'OpenConnectBrowserResult',
  '2': [
    {'1': 'finalURL', '3': 1, '4': 1, '5': 9, '10': 'finalURL'},
    {
      '1': 'cookies',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.daemon.OpenConnectBrowserCookie',
      '10': 'cookies'
    },
    {
      '1': 'headers',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.daemon.OpenConnectBrowserHeader',
      '10': 'headers'
    },
  ],
};

/// Descriptor for `OpenConnectBrowserResult`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectBrowserResultDescriptor = $convert.base64Decode(
    'ChhPcGVuQ29ubmVjdEJyb3dzZXJSZXN1bHQSGgoIZmluYWxVUkwYASABKAlSCGZpbmFsVVJMEj'
    'oKB2Nvb2tpZXMYAiADKAsyIC5kYWVtb24uT3BlbkNvbm5lY3RCcm93c2VyQ29va2llUgdjb29r'
    'aWVzEjoKB2hlYWRlcnMYAyADKAsyIC5kYWVtb24uT3BlbkNvbm5lY3RCcm93c2VySGVhZGVyUg'
    'doZWFkZXJz');

@$core.Deprecated('Use openConnectAuthResponseSubmissionDescriptor instead')
const OpenConnectAuthResponseSubmission$json = {
  '1': 'OpenConnectAuthResponseSubmission',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'challengeID', '3': 2, '4': 1, '5': 9, '10': 'challengeID'},
    {
      '1': 'form',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.daemon.OpenConnectAuthFormResponse',
      '9': 0,
      '10': 'form'
    },
    {
      '1': 'browser',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.daemon.OpenConnectBrowserResult',
      '9': 0,
      '10': 'browser'
    },
  ],
  '8': [
    {'1': 'response'},
  ],
};

/// Descriptor for `OpenConnectAuthResponseSubmission`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectAuthResponseSubmissionDescriptor = $convert.base64Decode(
    'CiFPcGVuQ29ubmVjdEF1dGhSZXNwb25zZVN1Ym1pc3Npb24SIAoLZW5kcG9pbnRUYWcYASABKA'
    'lSC2VuZHBvaW50VGFnEiAKC2NoYWxsZW5nZUlEGAIgASgJUgtjaGFsbGVuZ2VJRBI5CgRmb3Jt'
    'GAMgASgLMiMuZGFlbW9uLk9wZW5Db25uZWN0QXV0aEZvcm1SZXNwb25zZUgAUgRmb3JtEjwKB2'
    'Jyb3dzZXIYBCABKAsyIC5kYWVtb24uT3BlbkNvbm5lY3RCcm93c2VyUmVzdWx0SABSB2Jyb3dz'
    'ZXJCCgoIcmVzcG9uc2U=');

@$core.Deprecated('Use openConnectAuthChallengeCancelDescriptor instead')
const OpenConnectAuthChallengeCancel$json = {
  '1': 'OpenConnectAuthChallengeCancel',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'challengeID', '3': 2, '4': 1, '5': 9, '10': 'challengeID'},
  ],
};

/// Descriptor for `OpenConnectAuthChallengeCancel`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openConnectAuthChallengeCancelDescriptor =
    $convert.base64Decode(
        'Ch5PcGVuQ29ubmVjdEF1dGhDaGFsbGVuZ2VDYW5jZWwSIAoLZW5kcG9pbnRUYWcYASABKAlSC2'
        'VuZHBvaW50VGFnEiAKC2NoYWxsZW5nZUlEGAIgASgJUgtjaGFsbGVuZ2VJRA==');

@$core.Deprecated('Use openVPNStatusUpdateDescriptor instead')
const OpenVPNStatusUpdate$json = {
  '1': 'OpenVPNStatusUpdate',
  '2': [
    {
      '1': 'endpoints',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.daemon.OpenVPNEndpointStatus',
      '10': 'endpoints'
    },
  ],
};

/// Descriptor for `OpenVPNStatusUpdate`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openVPNStatusUpdateDescriptor = $convert.base64Decode(
    'ChNPcGVuVlBOU3RhdHVzVXBkYXRlEjsKCWVuZHBvaW50cxgBIAMoCzIdLmRhZW1vbi5PcGVuVl'
    'BORW5kcG9pbnRTdGF0dXNSCWVuZHBvaW50cw==');

@$core.Deprecated('Use openVPNEndpointStatusDescriptor instead')
const OpenVPNEndpointStatus$json = {
  '1': 'OpenVPNEndpointStatus',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'state', '3': 2, '4': 1, '5': 9, '10': 'state'},
    {'1': 'stateText', '3': 3, '4': 1, '5': 9, '10': 'stateText'},
    {
      '1': 'challenge',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.daemon.OpenVPNChallenge',
      '10': 'challenge'
    },
    {'1': 'error', '3': 5, '4': 1, '5': 9, '10': 'error'},
    {
      '1': 'tunnelInfo',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.daemon.OpenVPNTunnelInfo',
      '10': 'tunnelInfo'
    },
  ],
};

/// Descriptor for `OpenVPNEndpointStatus`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openVPNEndpointStatusDescriptor = $convert.base64Decode(
    'ChVPcGVuVlBORW5kcG9pbnRTdGF0dXMSIAoLZW5kcG9pbnRUYWcYASABKAlSC2VuZHBvaW50VG'
    'FnEhQKBXN0YXRlGAIgASgJUgVzdGF0ZRIcCglzdGF0ZVRleHQYAyABKAlSCXN0YXRlVGV4dBI2'
    'CgljaGFsbGVuZ2UYBCABKAsyGC5kYWVtb24uT3BlblZQTkNoYWxsZW5nZVIJY2hhbGxlbmdlEh'
    'QKBWVycm9yGAUgASgJUgVlcnJvchI5Cgp0dW5uZWxJbmZvGAYgASgLMhkuZGFlbW9uLk9wZW5W'
    'UE5UdW5uZWxJbmZvUgp0dW5uZWxJbmZv');

@$core.Deprecated('Use openVPNTunnelInfoDescriptor instead')
const OpenVPNTunnelInfo$json = {
  '1': 'OpenVPNTunnelInfo',
  '2': [
    {'1': 'server', '3': 1, '4': 1, '5': 9, '10': 'server'},
    {'1': 'network', '3': 3, '4': 1, '5': 9, '10': 'network'},
    {'1': 'ipv4', '3': 4, '4': 3, '5': 9, '10': 'ipv4'},
    {'1': 'ipv6', '3': 5, '4': 3, '5': 9, '10': 'ipv6'},
    {'1': 'dns', '3': 6, '4': 3, '5': 9, '10': 'dns'},
    {'1': 'mtu', '3': 7, '4': 1, '5': 13, '10': 'mtu'},
    {'1': 'connectedSince', '3': 8, '4': 1, '5': 3, '10': 'connectedSince'},
    {'1': 'cipher', '3': 9, '4': 1, '5': 9, '10': 'cipher'},
  ],
  '9': [
    {'1': 2, '2': 3},
  ],
};

/// Descriptor for `OpenVPNTunnelInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openVPNTunnelInfoDescriptor = $convert.base64Decode(
    'ChFPcGVuVlBOVHVubmVsSW5mbxIWCgZzZXJ2ZXIYASABKAlSBnNlcnZlchIYCgduZXR3b3JrGA'
    'MgASgJUgduZXR3b3JrEhIKBGlwdjQYBCADKAlSBGlwdjQSEgoEaXB2NhgFIAMoCVIEaXB2NhIQ'
    'CgNkbnMYBiADKAlSA2RucxIQCgNtdHUYByABKA1SA210dRImCg5jb25uZWN0ZWRTaW5jZRgIIA'
    'EoA1IOY29ubmVjdGVkU2luY2USFgoGY2lwaGVyGAkgASgJUgZjaXBoZXJKBAgCEAM=');

@$core.Deprecated('Use openVPNChallengeDescriptor instead')
const OpenVPNChallenge$json = {
  '1': 'OpenVPNChallenge',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'kind', '3': 2, '4': 1, '5': 9, '10': 'kind'},
    {'1': 'username', '3': 3, '4': 1, '5': 9, '10': 'username'},
    {'1': 'message', '3': 4, '4': 1, '5': 9, '10': 'message'},
    {'1': 'url', '3': 5, '4': 1, '5': 9, '10': 'url'},
    {'1': 'secretMessage', '3': 6, '4': 1, '5': 9, '10': 'secretMessage'},
    {'1': 'echo', '3': 7, '4': 1, '5': 8, '10': 'echo'},
    {'1': 'previousError', '3': 8, '4': 1, '5': 9, '10': 'previousError'},
    {'1': 'deadline', '3': 9, '4': 1, '5': 3, '10': 'deadline'},
  ],
};

/// Descriptor for `OpenVPNChallenge`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openVPNChallengeDescriptor = $convert.base64Decode(
    'ChBPcGVuVlBOQ2hhbGxlbmdlEg4KAmlkGAEgASgJUgJpZBISCgRraW5kGAIgASgJUgRraW5kEh'
    'oKCHVzZXJuYW1lGAMgASgJUgh1c2VybmFtZRIYCgdtZXNzYWdlGAQgASgJUgdtZXNzYWdlEhAK'
    'A3VybBgFIAEoCVIDdXJsEiQKDXNlY3JldE1lc3NhZ2UYBiABKAlSDXNlY3JldE1lc3NhZ2USEg'
    'oEZWNobxgHIAEoCFIEZWNobxIkCg1wcmV2aW91c0Vycm9yGAggASgJUg1wcmV2aW91c0Vycm9y'
    'EhoKCGRlYWRsaW5lGAkgASgDUghkZWFkbGluZQ==');

@$core.Deprecated('Use openVPNChallengeSubmissionDescriptor instead')
const OpenVPNChallengeSubmission$json = {
  '1': 'OpenVPNChallengeSubmission',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'challengeID', '3': 2, '4': 1, '5': 9, '10': 'challengeID'},
    {'1': 'username', '3': 3, '4': 1, '5': 9, '10': 'username'},
    {'1': 'password', '3': 4, '4': 1, '5': 9, '10': 'password'},
    {'1': 'secret', '3': 5, '4': 1, '5': 9, '10': 'secret'},
  ],
};

/// Descriptor for `OpenVPNChallengeSubmission`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openVPNChallengeSubmissionDescriptor = $convert.base64Decode(
    'ChpPcGVuVlBOQ2hhbGxlbmdlU3VibWlzc2lvbhIgCgtlbmRwb2ludFRhZxgBIAEoCVILZW5kcG'
    '9pbnRUYWcSIAoLY2hhbGxlbmdlSUQYAiABKAlSC2NoYWxsZW5nZUlEEhoKCHVzZXJuYW1lGAMg'
    'ASgJUgh1c2VybmFtZRIaCghwYXNzd29yZBgEIAEoCVIIcGFzc3dvcmQSFgoGc2VjcmV0GAUgAS'
    'gJUgZzZWNyZXQ=');

@$core.Deprecated('Use openVPNChallengeCancelDescriptor instead')
const OpenVPNChallengeCancel$json = {
  '1': 'OpenVPNChallengeCancel',
  '2': [
    {'1': 'endpointTag', '3': 1, '4': 1, '5': 9, '10': 'endpointTag'},
    {'1': 'challengeID', '3': 2, '4': 1, '5': 9, '10': 'challengeID'},
  ],
};

/// Descriptor for `OpenVPNChallengeCancel`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openVPNChallengeCancelDescriptor =
    $convert.base64Decode(
        'ChZPcGVuVlBOQ2hhbGxlbmdlQ2FuY2VsEiAKC2VuZHBvaW50VGFnGAEgASgJUgtlbmRwb2ludF'
        'RhZxIgCgtjaGFsbGVuZ2VJRBgCIAEoCVILY2hhbGxlbmdlSUQ=');

@$core.Deprecated('Use notificationEventDescriptor instead')
const NotificationEvent$json = {
  '1': 'NotificationEvent',
  '2': [
    {
      '1': 'send',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.daemon.Notification',
      '9': 0,
      '10': 'send'
    },
    {
      '1': 'cancel',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.daemon.NotificationCancel',
      '9': 0,
      '10': 'cancel'
    },
  ],
  '8': [
    {'1': 'event'},
  ],
};

/// Descriptor for `NotificationEvent`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List notificationEventDescriptor = $convert.base64Decode(
    'ChFOb3RpZmljYXRpb25FdmVudBIqCgRzZW5kGAEgASgLMhQuZGFlbW9uLk5vdGlmaWNhdGlvbk'
    'gAUgRzZW5kEjQKBmNhbmNlbBgCIAEoCzIaLmRhZW1vbi5Ob3RpZmljYXRpb25DYW5jZWxIAFIG'
    'Y2FuY2VsQgcKBWV2ZW50');

@$core.Deprecated('Use notificationDescriptor instead')
const Notification$json = {
  '1': 'Notification',
  '2': [
    {'1': 'identifier', '3': 1, '4': 1, '5': 9, '10': 'identifier'},
    {'1': 'typeName', '3': 2, '4': 1, '5': 9, '10': 'typeName'},
    {'1': 'typeID', '3': 3, '4': 1, '5': 5, '10': 'typeID'},
    {'1': 'title', '3': 4, '4': 1, '5': 9, '10': 'title'},
    {'1': 'subtitle', '3': 5, '4': 1, '5': 9, '10': 'subtitle'},
    {'1': 'body', '3': 6, '4': 1, '5': 9, '10': 'body'},
    {'1': 'openURL', '3': 7, '4': 1, '5': 9, '10': 'openURL'},
  ],
};

/// Descriptor for `Notification`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List notificationDescriptor = $convert.base64Decode(
    'CgxOb3RpZmljYXRpb24SHgoKaWRlbnRpZmllchgBIAEoCVIKaWRlbnRpZmllchIaCgh0eXBlTm'
    'FtZRgCIAEoCVIIdHlwZU5hbWUSFgoGdHlwZUlEGAMgASgFUgZ0eXBlSUQSFAoFdGl0bGUYBCAB'
    'KAlSBXRpdGxlEhoKCHN1YnRpdGxlGAUgASgJUghzdWJ0aXRsZRISCgRib2R5GAYgASgJUgRib2'
    'R5EhgKB29wZW5VUkwYByABKAlSB29wZW5VUkw=');

@$core.Deprecated('Use notificationCancelDescriptor instead')
const NotificationCancel$json = {
  '1': 'NotificationCancel',
  '2': [
    {'1': 'identifier', '3': 1, '4': 1, '5': 9, '10': 'identifier'},
    {'1': 'typeID', '3': 2, '4': 1, '5': 5, '10': 'typeID'},
  ],
};

/// Descriptor for `NotificationCancel`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List notificationCancelDescriptor = $convert.base64Decode(
    'ChJOb3RpZmljYXRpb25DYW5jZWwSHgoKaWRlbnRpZmllchgBIAEoCVIKaWRlbnRpZmllchIWCg'
    'Z0eXBlSUQYAiABKAVSBnR5cGVJRA==');
