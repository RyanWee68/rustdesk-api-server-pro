import { request } from '../request';

export type DeviceAdmissionPayload = {
  id?: number;
  rustdesk_id?: string;
  reason?: string;
};

export type DeviceRelayPayload = {
  id?: number;
  rustdesk_id?: string;
  allow_relay: boolean;
};

export function fetchDevicesList(params: Api.Devices.DeviceSearchParams) {
  return request<Api.Devices.DevicesList>({ url: '/devices/list', params });
}

export function approveDevice(data: DeviceAdmissionPayload) {
  return request({ url: '/devices/approve', method: 'post', data });
}

export function rejectDevice(data: DeviceAdmissionPayload) {
  return request({ url: '/devices/reject', method: 'post', data });
}

export function disableDevice(data: DeviceAdmissionPayload) {
  return request({ url: '/devices/disable', method: 'post', data });
}

export function enableDevice(data: DeviceAdmissionPayload) {
  return request({ url: '/devices/enable', method: 'post', data });
}

export function updateDeviceRelay(data: DeviceRelayPayload) {
  return request({ url: '/devices/relay', method: 'post', data });
}
