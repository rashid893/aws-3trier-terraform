from django.db import models


class PageView(models.Model):
    """Track page views to verify database connectivity."""
    path = models.CharField(max_length=255)
    hostname = models.CharField(max_length=255)
    timestamp = models.DateTimeField(auto_now_add=True)
    ip_address = models.GenericIPAddressField(null=True, blank=True)

    class Meta:
        ordering = ['-timestamp']

    def __str__(self):
        return f"{self.path} from {self.hostname} at {self.timestamp}"
