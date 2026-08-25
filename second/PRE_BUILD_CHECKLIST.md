# Observatory — Pre-Build Checklist
## Required before every version

### Scope
- [ ] Version name and one-sentence purpose
- [ ] Explicit non-goals
- [ ] Requirements advanced
- [ ] Constraints that must not be violated

### Architecture
- [ ] New/changed entities and ownership
- [ ] Source adapter / normalization / storage boundaries identified
- [ ] Backward compatibility confirmed
- [ ] Rollback plan documented

### Libraries and logic
- [ ] Any phrase/pattern logic uses a library or has a migration ticket
- [ ] Library/rule provenance and version are retained
- [ ] No new permanent hard-coded criteria

### Evidence and safety
- [ ] Output has evidence, timestamp, confidence/quality, and provenance
- [ ] Claims match available time scope
- [ ] No diagnosis or causal claim is introduced
- [ ] Escalation/safety implications reviewed

### UX
- [ ] Primary user benefit is clear
- [ ] Insight-first hierarchy preserved
- [ ] Evidence is progressively disclosed
- [ ] Empty/insufficient-data states are useful and non-punitive

### Validation
- [ ] Test cases include missing data, ambiguous data, multiple speakers, and conflicting signals
- [ ] Build/run test completed
- [ ] Git commit/tag/archive plan defined
