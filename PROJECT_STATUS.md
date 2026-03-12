“已完成” (Completed)：

✅ 考勤照片上传与 Firestore 关联。

✅ 考勤历史记录显示与状态同步。

✅ “欠工时 (Under time)”与“加班 (OT)”自动计算逻辑。

✅ 带有 GPS 和时间戳水印的相机功能。

✅ 打卡前的人脸识别验证。

“待办” (Real To-Do)：

🔲 地理围栏强制拦截：在 _submitAttendance 中正式加入 isWithinRange 的判断，若不在办公区则拒绝提交。

🔲 导出报表：实现考勤历史导出为 PDF/Excel 的功能。

🔲 推送通知：提醒员工上下班打卡。