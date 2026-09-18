(function () {
  var el = document.getElementById('severity-chart');
  if (!el || typeof echarts === 'undefined') return;

  // 读取报告主题令牌，保证图表与页面同一调色板
  var css = getComputedStyle(document.documentElement);
  function token(name, fallback) {
    var v = css.getPropertyValue(name).trim();
    return v || fallback;
  }
  var colorHigh = token('--chart-negative', '#FF4D4F');
  var colorMedium = token('--chart-warning', '#FAAD14');
  var colorLow = token('--chart-axis', '#667A74');
  var gridColor = token('--chart-grid', 'rgba(27,43,39,0.12)');
  var axisColor = token('--chart-axis', '#667A74');
  var labelColor = token('--chart-label', '#667A74');
  var tooltipBg = token('--chart-tooltip-bg', '#FFFFFF');

  var chart = echarts.init(el, null, { renderer: 'svg' });
  chart.setOption({
    animation: false,
    grid: { left: 8, right: 16, top: 40, bottom: 8, containLabel: true },
    legend: {
      bottom: 0,
      itemWidth: 12,
      itemHeight: 12,
      icon: 'circle',
      textStyle: { color: labelColor, fontSize: 12 }
    },
    tooltip: {
      trigger: 'axis',
      axisPointer: { type: 'shadow' },
      appendToBody: true,
      backgroundColor: tooltipBg,
      borderColor: gridColor,
      textStyle: { color: '#1B2B27', fontSize: 12 },
      valueFormatter: function (v) { return v + ' 项'; }
    },
    xAxis: {
      type: 'value',
      minInterval: 1,
      axisLabel: { color: axisColor, fontSize: 11 },
      splitLine: { lineStyle: { color: gridColor, width: 1 } }
    },
    yAxis: {
      type: 'category',
      data: ['功能与安全', '性能', 'UI/UX'],
      axisLabel: { color: labelColor, fontSize: 12 },
      axisLine: { lineStyle: { color: gridColor } },
      axisTick: { show: false }
    },
    series: [
      {
        name: '高',
        type: 'bar',
        stack: 'total',
        barWidth: 34,
        itemStyle: { color: colorHigh, borderRadius: [4, 4, 0, 0] },
        data: [1, 1, 1]
      },
      {
        name: '中',
        type: 'bar',
        stack: 'total',
        itemStyle: { color: colorMedium },
        data: [7, 12, 7]
      },
      {
        name: '低',
        type: 'bar',
        stack: 'total',
        itemStyle: { color: colorLow, borderRadius: [0, 0, 4, 4] },
        data: [6, 15, 12]
      }
    ]
  });

  window.addEventListener('resize', function () { chart.resize(); });
})();
