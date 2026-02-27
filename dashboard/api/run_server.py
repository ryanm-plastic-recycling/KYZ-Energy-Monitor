import os

import uvicorn
from dotenv import load_dotenv


def main() -> None:
    load_dotenv()
    host = os.getenv("DASHBOARD_HOST", "0.0.0.0")
    port = int(os.getenv("DASHBOARD_PORT", "8080"))
    uvicorn.run("dashboard.api.app:app", host=host, port=port, log_config=None)


if __name__ == "__main__":
    main()
