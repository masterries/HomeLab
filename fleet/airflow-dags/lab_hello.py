"""lab_hello - a small example DAG of the lab, deployed by git-sync from this repository.

Airflow's git-sync sidecars pull fleet/airflow-dags from GitHub every 60 seconds
(fleet/airflow/fleet.yaml, dags.gitSync), and the dag-processor looks for new files every 60
seconds (config.dag_processor.refresh_interval), so a change pushed here appears in Airflow within
about two minutes: GitOps for the DAGs, as Fleet does it for the stack itself.

Three tasks in a row, the classic extract - transform - load, written with the TaskFlow API:
each function is a task, and what one returns reaches the next through XCom (stored in the
metadata database). The scheduler queues them in Redis, the Celery worker runs them; watch it in
the UI (Graph, Logs) and the traffic between the pods in Hubble UI (namespace airflow).
"""

from datetime import datetime

from airflow.sdk import dag, task


@dag(
    dag_id="lab_hello",
    schedule="@hourly",
    start_date=datetime(2026, 10, 1),
    catchup=False,
    tags=["lab", "example"],
)
def lab_hello():
    @task
    def extract() -> list[int]:
        # A real pipeline would read from an API, a database or a bucket here.
        return [3, 1, 4, 1, 5, 9, 2, 6]

    @task
    def transform(numbers: list[int]) -> dict:
        return {"count": len(numbers), "sum": sum(numbers), "max": max(numbers)}

    @task
    def load(summary: dict) -> None:
        # ...and write the result somewhere; here it only goes to the task log.
        print(f"Summary of this run: {summary}")

    load(transform(extract()))


lab_hello()
