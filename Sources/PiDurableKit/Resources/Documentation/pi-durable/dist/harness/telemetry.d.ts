/** Durable's content-free span, event, and metric vocabulary. IDs address durable records, never content. */
export declare const DURABLE_TELEMETRY_SCHEMA: {
    readonly version: 1;
    readonly spans: {
        readonly "pi.durable.submit": {
            readonly description: "Public submission admission and its commit. Inputs start root traces linked to their callers; writes are children. Internal admissions emit phase events only.";
            readonly parents: {
                readonly kind: "any";
            };
            readonly startAttributes: {
                readonly "submission.type": {
                    readonly type: "string";
                    readonly required: true;
                    readonly values: readonly ["input", "write"];
                    readonly description: "Submission type.";
                };
                readonly "conversation.id": {
                    readonly type: "number";
                    readonly required: true;
                    readonly description: "Conversation ID.";
                    readonly cardinality: "high";
                };
            };
            readonly endAttributes: {
                readonly "submission.id": {
                    readonly type: "number";
                    readonly description: "Admitted submission ID.";
                    readonly cardinality: "high";
                };
                readonly result: {
                    readonly type: "string";
                    readonly values: readonly ["queued", "placed", "done"];
                    readonly description: "Admission result; stale writes report done.";
                };
            };
            readonly events: {
                "pi.durable.entry": {
                    readonly description: "A transcript entry was committed; content remains in the transcript.";
                    readonly attributes: {
                        readonly "entry.id": {
                            readonly type: "number";
                            readonly required: true;
                            readonly description: "Transcript entry ID.";
                            readonly cardinality: "high";
                        };
                        readonly "entry.kind": {
                            readonly type: "string";
                            readonly required: true;
                            readonly description: "Entry kind.";
                        };
                    };
                };
                "pi.durable.submission": {
                    readonly description: "A submission was settled.";
                    readonly attributes: {
                        readonly "submission.id": {
                            readonly type: "number";
                            readonly required: true;
                            readonly description: "Submission ID.";
                            readonly cardinality: "high";
                        };
                        readonly status: {
                            readonly type: "string";
                            readonly required: true;
                            readonly values: readonly ["done", "unanswered"];
                            readonly description: "Settlement.";
                        };
                        readonly "answer.entry_id": {
                            readonly type: "number";
                            readonly required: false;
                            readonly description: "Answer entry ID.";
                            readonly cardinality: "high";
                        };
                    };
                };
                "pi.durable.report": {
                    readonly description: "A report was raised; no error payload is recorded.";
                    readonly attributes: {
                        readonly type: {
                            readonly type: "string";
                            readonly required: true;
                            readonly description: "ReportInfo type.";
                            readonly values: readonly ["session_failed", "task_faulted", "task_parked", "migration_failed", "task_outdated", "task_error", "extension_error", "host_error", "listener_error"];
                        };
                        readonly reason: {
                            readonly type: "string";
                            readonly required: false;
                            readonly description: "Fixed report reason, when present.";
                            readonly values: readonly ["threw", "restart_limit", "missing_task", "incompatible_task"];
                        };
                        readonly extension: {
                            readonly type: "string";
                            readonly required: false;
                            readonly description: "Registered extension name, when present.";
                        };
                        readonly "task.id": {
                            readonly type: "number";
                            readonly required: false;
                            readonly description: "Task ID, when present.";
                            readonly cardinality: "high";
                        };
                    };
                };
            };
            readonly status: {
                readonly default: "ok";
                readonly errorWhen: "Admission failed.";
            };
        };
        readonly "pi.durable.phase": {
            readonly description: "One task phase invocation, including its decision commit, never a wait or restart.";
            readonly parents: {
                readonly kind: "any";
            };
            readonly startAttributes: {
                readonly "task.id": {
                    readonly type: "number";
                    readonly required: true;
                    readonly description: "Task ID.";
                    readonly cardinality: "high";
                };
                readonly "task.name": {
                    readonly type: "string";
                    readonly required: true;
                    readonly description: "Registered task name.";
                };
                readonly phase: {
                    readonly type: "string";
                    readonly required: true;
                    readonly description: "Invoked checkpoint phase.";
                };
                readonly kind: {
                    readonly type: "string";
                    readonly required: true;
                    readonly values: readonly ["run", "abort"];
                    readonly description: "Invocation kind.";
                };
                readonly attempt: {
                    readonly type: "number";
                    readonly required: false;
                    readonly description: "Checkpoint attempt, when present.";
                };
                readonly resumed: {
                    readonly type: "boolean";
                    readonly required: true;
                    readonly description: "First invocation of a task loaded in this process.";
                };
            };
            readonly endAttributes: {
                readonly outcome: {
                    readonly type: "string";
                    readonly description: "next=<phase>, waiting, sleeping, done, faulted, or aborted.";
                };
                readonly "tool.name": {
                    readonly type: "string";
                    readonly description: "Called tool name.";
                };
                readonly "tool.call_id": {
                    readonly type: "string";
                    readonly description: "Transcript tool call ID.";
                    readonly cardinality: "high";
                };
            };
            readonly events: {
                readonly "pi.durable.entry": {
                    readonly description: "A transcript entry was committed; content remains in the transcript.";
                    readonly attributes: {
                        readonly "entry.id": {
                            readonly type: "number";
                            readonly required: true;
                            readonly description: "Transcript entry ID.";
                            readonly cardinality: "high";
                        };
                        readonly "entry.kind": {
                            readonly type: "string";
                            readonly required: true;
                            readonly description: "Entry kind.";
                        };
                    };
                };
                readonly "pi.durable.submission": {
                    readonly description: "A submission was settled.";
                    readonly attributes: {
                        readonly "submission.id": {
                            readonly type: "number";
                            readonly required: true;
                            readonly description: "Submission ID.";
                            readonly cardinality: "high";
                        };
                        readonly status: {
                            readonly type: "string";
                            readonly required: true;
                            readonly values: readonly ["done", "unanswered"];
                            readonly description: "Settlement.";
                        };
                        readonly "answer.entry_id": {
                            readonly type: "number";
                            readonly required: false;
                            readonly description: "Answer entry ID.";
                            readonly cardinality: "high";
                        };
                    };
                };
                readonly "pi.durable.report": {
                    readonly description: "A report was raised; no error payload is recorded.";
                    readonly attributes: {
                        readonly type: {
                            readonly type: "string";
                            readonly required: true;
                            readonly description: "ReportInfo type.";
                            readonly values: readonly ["session_failed", "task_faulted", "task_parked", "migration_failed", "task_outdated", "task_error", "extension_error", "host_error", "listener_error"];
                        };
                        readonly reason: {
                            readonly type: "string";
                            readonly required: false;
                            readonly description: "Fixed report reason, when present.";
                            readonly values: readonly ["threw", "restart_limit", "missing_task", "incompatible_task"];
                        };
                        readonly extension: {
                            readonly type: "string";
                            readonly required: false;
                            readonly description: "Registered extension name, when present.";
                        };
                        readonly "task.id": {
                            readonly type: "number";
                            readonly required: false;
                            readonly description: "Task ID, when present.";
                            readonly cardinality: "high";
                        };
                    };
                };
                readonly "pi.durable.checkpoint": {
                    readonly description: "The running checkpoint's phase changed while the invocation continued.";
                    readonly attributes: {
                        readonly phase: {
                            readonly type: "string";
                            readonly required: true;
                            readonly description: "Committed checkpoint phase.";
                        };
                    };
                };
                readonly "pi.durable.replay": {
                    readonly description: "A nested tool call was answered from its stored result.";
                    readonly attributes: {
                        readonly "tool.name": {
                            readonly type: "string";
                            readonly required: true;
                            readonly description: "Called tool name.";
                        };
                    };
                };
            };
            readonly status: {
                readonly default: "ok";
                readonly errorWhen: "Faulted, failed, and orphaned outcomes use task_faulted, task_failed, and task_orphaned with a diagnostic capped at 500 characters. Aborted outcomes keep status ok.";
            };
        };
    };
    readonly metrics: {
        readonly "pi.durable.reports": {
            readonly kind: "counter";
            readonly description: "Reports raised, grouped by their fixed ReportInfo type.";
            readonly attributes: {
                type: {
                    readonly type: "string";
                    readonly required: true;
                    readonly description: "ReportInfo type.";
                    readonly values: readonly ["session_failed", "task_faulted", "task_parked", "migration_failed", "task_outdated", "task_error", "extension_error", "host_error", "listener_error"];
                };
            };
        };
        readonly "pi.durable.phase.duration": {
            readonly kind: "histogram";
            readonly unit: "ms";
            readonly description: "Duration of a phase invocation and its decision commit.";
            readonly attributes: {
                readonly task: {
                    readonly type: "string";
                    readonly required: true;
                    readonly description: "Registered task name.";
                };
                readonly phase: {
                    readonly type: "string";
                    readonly required: true;
                    readonly description: "Invoked checkpoint phase.";
                };
                readonly outcome: {
                    readonly type: "string";
                    readonly required: true;
                    readonly description: "Phase outcome.";
                };
            };
        };
        readonly "pi.durable.tasks.active": {
            readonly kind: "upDownCounter";
            readonly description: "Live tasks held by this Harness; decremented at terminal settlement or close.";
            readonly attributes: {
                readonly task: {
                    readonly type: "string";
                    readonly required: true;
                    readonly description: "Registered task name.";
                };
            };
        };
    };
};
