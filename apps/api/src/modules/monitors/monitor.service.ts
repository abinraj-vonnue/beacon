import * as monitorRepository from "./monitor.repository.js";
import { CreateMonitorInput, UpdateMonitorInput } from "./monitor.schema.js";

export async function createMonitor(data: CreateMonitorInput) {
  return monitorRepository.createMonitor(data);
}

export async function listMonitors() {
  return monitorRepository.listMonitors();
}
export async function getMonitor(id: string) {
  return monitorRepository.findMonitorById(id);
}

export async function updateMonitor(id: string, data: UpdateMonitorInput) {
  return monitorRepository.updateMonitor(id, data);
}

export async function deleteMonitor(id: string) {
  return monitorRepository.deleteMonitor(id);
}
