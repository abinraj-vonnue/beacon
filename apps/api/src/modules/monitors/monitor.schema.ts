import { z } from "zod";

const httpUrlSchema = z.url().refine((value) => {
  const protocol = new URL(value).protocol;
  return protocol === "http:" || protocol === "https:";
}, "URL must use HTTP or HTTPS");

export const createMonitorSchema = z.object({
  name: z.string().trim().min(1).max(120),
  url: httpUrlSchema,
  interval_seconds: z.number().int().min(30).max(3600).default(60),
  timeout_ms: z.number().int().min(100).max(60000).default(5000),
  expected_status_code: z.number().int().min(100).max(599).default(200),
  enabled: z.boolean().default(true),
});

export const updateMonitorSchema = z
  .object({
    name: z.string().trim().min(1).max(120).optional(),
    url: httpUrlSchema.optional(),
    interval_seconds: z.number().int().min(30).max(3600).optional(),
    timeout_ms: z.number().int().min(100).max(60000).optional(),
    expected_status_code: z.number().int().min(100).max(599).optional(),
    enabled: z.boolean().optional(),
  })
  .refine((data) => Object.keys(data).length > 0, {
    message: "At least one field must be provided",
  });

export const monitorIdSchema = z.object({
  id: z.string().uuid(),
});

export type CreateMonitorInput = z.infer<typeof createMonitorSchema>;
export type UpdateMonitorInput = z.infer<typeof updateMonitorSchema>;
