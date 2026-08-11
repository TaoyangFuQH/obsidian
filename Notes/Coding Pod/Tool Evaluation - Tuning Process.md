Goal: to use human labeled set, and unlabeled set to tine our system, e.g., clinical coding, ed coding, etc


Input
- human labeled set: with codes, reasoning of coding(, citations of coding). limited amount
- unlabeled set: LLM codes, LLM reasoning and LLM citations; larger amount than human labeled set; multi-LLM labeling, LLM debating, LLM auto judge

eval / tuning on unlabeled set
- sanity check from LLM labels
	- uncertainty check / confidence check: multi-LLM labeling
	- malformation check, e.g., json format error
- LLM debating / LLM auto judging
	- one LLM labels --> another LLM re-labeling / anothe


eval / tuning on human labeled set
- performance metrics on codes: overall performance, distribution drift detection
- summarize error cases from raw inputs, codes, reasoning, citations -> prompt / logic tuning
- compare human labels and all above eval from LLM labels
	- e.g., uncertainty v.s. performance; confidence v.s. performance



