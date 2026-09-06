# OH diagnostic frames

`oh-upstream-frames.json` contains complete ServerEvent frames exported from the merged OH-1/OH-2 SessionStore tests at a9f6cfa. Inputs are real installer output in temporary homes, controlled normalized events, the committed sanitized 0.153.4 rollout fixture, and controlled corrupt/unreadable inputs. These are candidate replay outputs, not device captures or 0.153.4 certification. Repeated scenarios are deduplicated without altering retained frames.

Generation evidence (local, gitignored): `.scratch/observation-health-correction/evidence/phone/PhoneEvidenceOH1Tests.swift`, `PhoneEvidenceOH2Tests.swift`, `fixture-manifest.json`, and `mac-tests.log`. Original tests: `ObservationCorrectionTests.swift` and `RolloutClassificationTests.swift`. No real agent tasks, user configuration or credentials are used.

The phone test decodes the complete envelope with the pre-OH stored model (ece1e72) and the current model, feeds each frame through DashboardStore and renders the actual phone row. Device version/connection and actual approvals remain separate acceptance gates.
