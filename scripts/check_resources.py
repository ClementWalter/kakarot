# %% Imports
import logging
from pathlib import Path

import pandas as pd

from scripts.artifacts import get_artifacts

pd.set_option("display.max_rows", 500)
pd.set_option("display.max_columns", 10)
pd.set_option("display.width", 1000)
pd.set_option("max_colwidth", 400)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


# %% Main
def main():
    # %% Script constants
    artifact_name = Path("resources")
    base_branch_name = "main"
    current_name = "local"

    artifacts = get_artifacts(artifact_name, base_branch_name)

    # %% Build aggregated stat for checking resources evolution
    resources = [
        (
            pd.read_csv(
                artifact_name / artifact["head_branch"] / "resources.csv"
            ).assign(head_branch=artifact["head_branch"])
        )
        for artifact in artifacts.to_dict("records")
    ]
    if (artifact_name / "resources.csv").exists():
        resources.append(
            pd.read_csv(artifact_name / "resources.csv").assign(
                head_branch=current_name
            )
        )
    else:
        logger.info("No local resources found to compare against")

    all_resources = (
        # There shouldn't be any duplicated, but rn we only have the test name, so
        # to avoid any confusion we just drop them
        pd.concat(resources)
        .drop_duplicates(["head_branch", "test"], keep=False)
        .set_index(["head_branch", "test"])
    )
    average_summary = all_resources.groupby(level="head_branch").agg("mean").round(2)
    logger.info(f"Resources summary:\n{average_summary}")


# %% Run
if __name__ == "__main__":
    main()
