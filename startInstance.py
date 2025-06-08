import json
import boto3
import chinese_calendar as calendar
import time
from datetime import datetime, date, timezone, timedelta

client = boto3.client('lightsail')

def lambda_handler(event, context):
    # 检查是否为工作日
    today = date.today()
    # TEST
    # today = date(2025,6,10)
    if calendar.is_workday(today):
        try:
            # 1. 开启实例
            response = client.start_instance(instanceName='WordPress-1')
            operation_id = response['operations'][0]['id']
            
            # 2. 轮询操作状态（最多等待100秒）
            start_time = time.time()
            while time.time() - start_time < 100:
                op_status = client.get_operation(operationId=operation_id)['operation']['status']
                if op_status == 'Succeeded':
                    print("实例已开启")
                    return {"status": "started"}
                time.sleep(5)  # 每5秒检查一次
            
            # 3. 超时处理
            print("操作未在预期时间内完成")
            return {"status": "timeout", "operationId": operation_id}
            
        except Exception as e:
            print(f"错误: {str(e)}")
            raise
    else:
        print("今天不是工作日，不执行操作")
        return {"status": "not_workday", "date": str(today)}
# 结束函数