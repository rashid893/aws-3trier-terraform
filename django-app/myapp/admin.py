from django.contrib import admin
from .models import PageView


@admin.register(PageView)
class PageViewAdmin(admin.ModelAdmin):
    list_display = ('path', 'hostname', 'ip_address', 'timestamp')
    list_filter = ('hostname',)
    readonly_fields = ('timestamp',)
