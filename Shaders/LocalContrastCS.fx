/*
LocalContrastCS
By: Lord Of Lunacy

This shader makes use of the scatter capabilities of a compute shader to perform an adaptive IIR filter rather than
the traditional FIR filters normally used in image processing.

Arici, Tarik, and Yucel Altunbasak. “Image Local Contrast Enhancement Using Adaptive Non-Linear Filters.” 
2006 International Conference on Image Processing, 2006, https://doi.org/10.1109/icip.2006.313031. 
*/


#define DIVIDE_ROUNDING_UP(n, d) uint(((n) + (d) - 1) / (d))
#define FILTER_WIDTH 128
#define PIXELS_PER_THREAD 128
#define H_GROUPS uint2(DIVIDE_ROUNDING_UP(BUFFER_WIDTH, PIXELS_PER_THREAD), DIVIDE_ROUNDING_UP(BUFFER_HEIGHT, 64))
#define V_GROUPS uint2(DIVIDE_ROUNDING_UP(BUFFER_WIDTH, 64), DIVIDE_ROUNDING_UP(BUFFER_HEIGHT, PIXELS_PER_THREAD))
#define H_GROUP_SIZE uint2(1, 64)
#define V_GROUP_SIZE uint2(64, 1)
#define PI 3.1415962

#if __RESHADE__ < 50000 && __RENDERER__ == 0xc000
	#error
#endif
#if !(((__RENDERER__ >= 0xb000 && __RENDERER__ < 0x10000) || (__RENDERER__ >= 0x14300)) && __RESHADE__ >=40800)
	#error
#endif

namespace Spatial_IIR_Clarity
{
	texture BackBuffer:COLOR;
	texture Luma {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
	texture Blur0{Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
	texture Blur1{Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};

	sampler sBackBuffer{Texture = BackBuffer;};
	sampler sLuma {Texture = Luma;};
	sampler sBlur0{Texture = Blur0;};
	sampler sBlur1{Texture = Blur1;};
	
	
	storage wLuma{Texture = Luma;};
	storage wBlur0{Texture = Blur0;};
	storage wBlur1{Texture = Blur1;};
	
	uniform float Strength<
		ui_type = "slider";
		ui_label = "Strength";
		ui_min = 0; ui_max = 1;
		ui_step = 0.001;
	> = 1;
	
	
	
	uniform float WeightExponent<
		ui_type = "slider";
		ui_label = "Detail Sharpness";
		ui_tooltip = "Use this slider to determine how large of a region the shader considers to be local;\n"
		             "a larger number will correspond to a smaller region, and will result in sharper looking\n"
		             "details.";
		ui_min = 3; ui_max = 9;
	> = 5;
	
	//Constants used by research paper
	static const float a = 0.0039215686; 
	static const float b = 0.0274509804;
	static const float c = 0.0823529412;
	
	float GainCoefficient(float x, float a, float b, float c, float k)
	{
		float gain = (x < a) ? 0 :
			         (x < b) ? cos((PI * rcp(b - a) * x + PI - (PI * a) * rcp(b - a))) :
			         (x < c) ? cos((PI * rcp(c - b) * x - (PI * b) * rcp(c-b))) : 0;
		return gain * (k/2) + (k/2);
	}
	
	// Vertex shader generating a triangle covering the entire screen
	void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
	{
		texcoord.x = (id == 2) ? 2.0 : 0.0;
		texcoord.y = (id == 1) ? 2.0 : 0.0;
		position = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
	}

	void LumaPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float luma : SV_Target0)
	{
		luma = dot(tex2D(sBackBuffer, texcoord).rgb, float3(0.299, 0.587, 0.114));
	}

	/*
	Not as fast, but maybe to be explored later
	void HorizontalFilterCS0(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID)
	{
		float2 coord = float2(id.x * PIXELS_PER_THREAD, id.y * 2) + 1;
		float4 curr;
		float4 prev;
		float2 weight;
		prev.yz = tex2DgatherR(sLuma, float2(coord.x - FILTER_WIDTH - 1, coord.y) / float2(BUFFER_WIDTH, BUFFER_HEIGHT)).yz;
		for(int i = -FILTER_WIDTH; i < PIXELS_PER_THREAD; i += 2)
		{
			curr = tex2DgatherR(sLuma, float2(coord.x + i, coord.y) / float2(BUFFER_WIDTH, BUFFER_HEIGHT));
			weight = 1 - abs(curr.xw - prev.yz);
			weight = pow(abs(weight), WeightExponent);
			prev.xw = lerp(curr.xw, prev.yz, weight);
			weight = 1 - abs(curr.yz - prev.xw);
			weight = pow(abs(weight), WeightExponent);
			prev.yz = lerp(curr.yz, prev.xw, weight);
			if(i >= 0)
			{
				tex2Dstore(wBlur0, int2(coord.x + i, coord.y + 1), prev.xxxx);
				tex2Dstore(wBlur0, int2(coord.x + i + 1, coord.y + 1), prev.yyyy);
				tex2Dstore(wBlur0, int2(coord.x + i + 1, coord.y ), prev.zzzz);
				tex2Dstore(wBlur0, int2(coord.x + i, coord.y ), prev.wwww);
			}
		}
	}*/
	
	void HorizontalFilterCS0(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID)
	{
		float2 coord = float2(id.x * PIXELS_PER_THREAD, id.y) + 0.5;
		float curr;
		float prev;
		float weight;
		prev = tex2Dfetch(sLuma, float2(coord.x - FILTER_WIDTH, coord.y)).x;

		for(int i = -FILTER_WIDTH + 1; i < PIXELS_PER_THREAD; i++)
		{
			curr = tex2Dfetch(sLuma, float2(coord.x + i, coord.y)).x;
			weight = 1 - abs(curr - prev);
			weight = pow(abs(weight), WeightExponent);
			prev = lerp(curr, prev, weight);
			if(i >= 0)
			{
				tex2Dstore(wBlur0, int2(coord.x + i, coord.y), prev.xxxx);
			}
		}
	}
	
	void HorizontalFilterCS1(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID)
	{
		float2 coord = float2(id.x * PIXELS_PER_THREAD + PIXELS_PER_THREAD, id.y) + 0.5;
		float curr;
		float prev;
		float weight;
		prev = tex2Dfetch(sLuma, float2(coord.x + FILTER_WIDTH, coord.y)).x;

		for(int i = FILTER_WIDTH - 1; i > -PIXELS_PER_THREAD; i--)
		{
			curr = tex2Dfetch(sLuma, float2(coord.x + i, coord.y)).x;
			weight = 1 - abs(curr - prev);
			weight = pow(abs(weight), WeightExponent);
			prev = lerp(curr, prev, weight);
			if(i <= 0)
			{
				float storedSample = (prev + tex2Dfetch(sBlur0, int2(coord.x + i, coord.y)).x) * 0.5;
				barrier();
				tex2Dstore(wBlur1, int2(coord.x + i, coord.y), storedSample.xxxx);
			}
		}
	}
	
	void VerticalFilterCS0(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID)
	{
		float2 coord = float2(id.x, id.y * PIXELS_PER_THREAD) + 0.5;
		float curr;
		float prev;
		float weight;
		prev = tex2Dfetch(sBlur1, float2(coord.x, coord.y - FILTER_WIDTH)).x;

		for(int i = -FILTER_WIDTH + 1; i < PIXELS_PER_THREAD; i++)
		{
			curr = tex2Dfetch(sBlur1, float2(coord.x, coord.y + i)).x;
			weight = 1 - abs(curr - prev);
			weight = pow(abs(weight), WeightExponent);
			prev = lerp(curr, prev, weight);
			if(i >= 0)
			{
				tex2Dstore(wBlur0, int2(coord.x, coord.y + i), prev.xxxx);
			}
		}
	}

	void VerticalFilterCS1(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID)
	{
		float2 coord = float2(id.x, id.y * PIXELS_PER_THREAD + PIXELS_PER_THREAD) + 0.5;
		float curr;
		float prev;
		float weight;
		prev = tex2Dfetch(sBlur1, float2(coord.x, coord.y + FILTER_WIDTH)).x;

		for(int i = FILTER_WIDTH - 1; i > -PIXELS_PER_THREAD; i--)
		{
			curr = tex2Dfetch(sBlur1, float2(coord.x, coord.y + i)).x;
			weight = 1 - abs(curr - prev);
			weight = pow(abs(weight), WeightExponent);
			prev = lerp(curr, prev, weight);
			if(i <= 0)
			{
				float storedSample = (prev + tex2Dfetch(sBlur0, int2(coord.x, coord.y + i)).x) * 0.5;
				tex2Dstore(wLuma, int2(coord.x, coord.y + i), storedSample.xxxx);
			}
		}
	}
	
	void OutputPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float4 output : SV_TARGET0)
	{
		float blur = tex2D(sLuma, texcoord).x;
		
		float3 color = tex2D(sBackBuffer, texcoord).rgb;
		float y = dot(color, float3(0.299, 0.587, 0.114));
		y += (y - blur) * GainCoefficient(abs(y-blur), a, b, c, Strength);
		float cb = dot(color, float3(-0.168736, -0.331264, 0.5));
		float cr = dot(color, float3(0.5, -0.418688, -0.081312));


		output.r = dot(float2(y, cr), float2(1, 1.402));//y + 1.402 * cr;
		output.g = dot(float3(y, cb, cr), float3(1, -0.344135, -0.714136));
		output.b = dot(float2(y, cb), float2(1, 1.772));//y + 1.772 * cb;
		output.a = 1;
	}
	
	technique LocalContrastCS <ui_tooltip = "A local contrast shader based on an adaptive infinite impulse response filter,\n"
	                                        "that adjusts the contrast of the image based on the amount of sorrounding contrast.\n\n"
                                                "Part of Insane Shaders\n"
                                                "By: Lord of Lunacy";>
	{	
		pass
		{
			VertexShader = PostProcessVS;
			PixelShader = LumaPS;
			RenderTarget0 = Luma;
		}
		
		pass
		{
			ComputeShader = HorizontalFilterCS0<H_GROUP_SIZE.x, H_GROUP_SIZE.y>;
			DispatchSizeX = H_GROUPS.x;
			DispatchSizeY = H_GROUPS.y;
		}
		
		pass
		{
			ComputeShader = HorizontalFilterCS1<H_GROUP_SIZE.x, H_GROUP_SIZE.y>;
			DispatchSizeX = H_GROUPS.x;
			DispatchSizeY = H_GROUPS.y;
		}
		
		pass
		{
			ComputeShader = VerticalFilterCS0<V_GROUP_SIZE.x, V_GROUP_SIZE.y>;
			DispatchSizeX = V_GROUPS.x;
			DispatchSizeY = V_GROUPS.y;
		}
		
		pass
		{
			ComputeShader = VerticalFilterCS1<V_GROUP_SIZE.x, V_GROUP_SIZE.y>;
			DispatchSizeX = V_GROUPS.x;
			DispatchSizeY = V_GROUPS.y;
		}
		
		pass
		{
			VertexShader = PostProcessVS;
			PixelShader = OutputPS;
		}
	}
}
