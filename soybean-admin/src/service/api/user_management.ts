import { request } from '../request';

export function fetchUserList(params: any) {
  return request<Api.UserManagement.UserList>({ url: '/users/list', params });
}

export function addUser(data: Api.UserManagement.User) {
  return request({ url: '/users/add', method: 'post', data });
}

export function editUser(data: Api.UserManagement.User) {
  return request({ url: '/users/edit', method: 'post', data });
}

export function getTOTP(data: Api.UserManagement.User) {
  return request({ url: '/users/totp', method: 'post', data });
}

export function delUser(data: any) {
  return request({ url: '/users/delete', method: 'post', data });
}

export function fetchSessionList(params: any) {
  return request<Api.UserManagement.SessionList>({ url: '/sessions/list', params });
}

export function killSession(data: any) {
  return request({ url: '/sessions/kill', method: 'post', data });
}

export function fetchSessionClear() {
  return request<any>({ url: '/sessions/clear', method: 'delete' });
}

export function fetchSecurityAuditClear() {
  return request<any>({ url: '/security-audit/clear', method: 'delete' });
}

export function fetchUserGroupList(params: any) {
  return request<Api.UserManagement.UserGroupList>({ url: '/user-groups/list', params });
}

export function saveUserGroup(data: { guid?: string; name: string }) {
  return request({ url: '/user-groups/save', method: 'post', data });
}

export function deleteUserGroup(guid: string) {
  return request({ url: '/user-groups/delete', method: 'delete', params: { guid } });
}

export function fetchUserGroupMembers(guid: string) {
  return request<{ records: Api.UserManagement.UserGroupMember[] }>({ url: '/user-groups/members', params: { guid } });
}

export function saveUserGroupMembers(data: { guid: string; userIds: number[] }) {
  return request({ url: '/user-groups/members', method: 'post', data });
}
