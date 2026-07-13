#Data Flow

User submits work

|

Job_service creates a Pending job

|

Memory persistence stores it

|

Worker_service registers a worker

|

Scheduling_service creates an assignment

|

Worker reports “started”

|

Execution_service changes states to Running

|

Worker reports success or failure

|

Execution_service completes the job or schedules a retry

|

Retry_service later returns an eligible retry to Pending
