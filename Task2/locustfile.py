from locust import HttpUser, between, task


class WebsiteUser(HttpUser):
    wait_time = between(1, 5)

    @task
    def index(self):
        # A new connection lets NodePort distribute requests across replicas.
        self.client.get("/", headers={"Connection": "close"})
