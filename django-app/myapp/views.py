import socket
import platform
from datetime import datetime

from django.shortcuts import render
from django.http import JsonResponse
from django.db import connection

from .models import PageView


def get_client_ip(request):
    x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
    if x_forwarded_for:
        return x_forwarded_for.split(',')[0].strip()
    return request.META.get('REMOTE_ADDR')


def index(request):
    """Main page — shows instance info and recent page views."""
    hostname = socket.gethostname()

    # Log this page view
    try:
        PageView.objects.create(
            path=request.path,
            hostname=hostname,
            ip_address=get_client_ip(request),
        )
        recent_views = PageView.objects.all()[:10]
        db_status = "Connected"
    except Exception as e:
        recent_views = []
        db_status = f"Error: {e}"

    context = {
        'hostname': hostname,
        'python_version': platform.python_version(),
        'db_status': db_status,
        'recent_views': recent_views,
        'server_time': datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC'),
    }
    return render(request, 'myapp/index.html', context)


def api_status(request):
    """JSON status endpoint for monitoring."""
    hostname = socket.gethostname()
    db_ok = False
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
        db_ok = True
    except Exception:
        pass

    return JsonResponse({
        'status': 'healthy' if db_ok else 'degraded',
        'hostname': hostname,
        'database': 'connected' if db_ok else 'disconnected',
        'timestamp': datetime.utcnow().isoformat(),
    })
